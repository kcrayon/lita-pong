require "elo2"
require "sqlite3"
require "time"

class MatchData
  def to_h
    names.zip(names.map{|n| self[n]}).to_h
  end
end

class TrueClass
  def to_i
    1
  end
end

class FalseClass
  def to_i
    0
  end
end

module Lita
  module Handlers
    class Pong < Handler
      namespace "pong"
      config :database, :type => String, :default => "/var/tmp/pong.db"
      config :default_rating, :type => Integer, :default => 1000
      config :pro_rating_boundry, :type => Integer, :default => 1200
      config :starter_boundry, :type => Integer, :default => 15

      route /^[Pp]ong (?<winner>\w+) (?:>|beat|won|destroyed|dominated) (?<loser>\w+)/, :record_match,
        :help => {"pong <winner> beat <loser>" => "record who a match"}
      route /^[Pp]ong (:?leaderboard|rank|ranking|score|scores)(:? from (?<from>today|week|month|all)|)$/, :leaderboard,
        :help => {"pong leaderboard (from <time>) " => "show the leaderboard"}
      route /^[Pp]ong (:?(?<all>all) |)matches(:? (?<player>\w+)|)(:? vs?\.? (?<versus>\w+)|)$/, :matches,
        :help => {"pong matches (<player>) (vs <other>) (from <time>)" => "show recent ping-pong matches"}
      route /^[Pp]ong (?<one>\w+) vs?\.? (?<two>\w+)(:? from (?<from>today|week|month|all)|)$/, :versus,
        :help => {"pong <player> vs <other>" => "show stats between two players"}
      route /^[Pp]ong player (?<player>\w+)(:? from (?<from>today|week|month|all)|)$/, :profile,
        :help => {"pong player <player> (from <time>)" => "show profile of <player>"}
      route /^[Pp]ong admin (?<cmd>\S+)(:? (?<arg>\S+)|)$/, :admin,
        :help => {"pong admin <cmd> <arg>" => "special admin commands, use with caution"}

      def admin(response)
        case response.match_data[:cmd]
        when "update-all"
          update_all
          response.reply("rebuilt all player profiles")
        when "hide-player", "unhide-player"
          player = response.match_data[:arg]
          new_state = (response.match_data[:cmd] == "hide-player")
          if set_hidden(:player => player, :hidden => new_state)
            response.reply("player #{player} hidden: #{new_state}")
          else
            response.reply("no such player: #{player}")
          end
        when "delete-match"
          id = response.match_data[:arg]
          match = db.execute("SELECT * FROM matches WHERE ROWID = ?", id).first
          if match
            db.execute("DELETE FROM matches WHERE ROWID = ?", id)
            update_all
            response.reply("deleted #{id}: #{format_time(match["created_at"])} - #{obfuscate(match["winner"])} > #{obfuscate(match["loser"])}")
          else
            response.reply("no such match: #{id}")
          end
        else
          response.reply("no such command")
        end
      end

      def record_match(response)
        winner = response.match_data[:winner].downcase
        loser =  response.match_data[:loser].downcase
        time = Time.now.utc.iso8601
        game = update_players(:winner => winner, :loser => loser)
        db.execute("INSERT INTO matches (winner, loser, created_at) VALUES (?, ?, ?)", winner, loser, time)
        match_id = db.last_insert_row_id
        winner_change, loser_change = game.ratings.values.map{|r| format("%+d", (r.new_rating - r.old_rating))}
        response.reply("match #{match_id} recorded: (#{winner_change}) #{winner} > #{loser} (#{loser_change})")
        leaderboard(response)
      end

      def matches(response)
        no_limit = (response.match_data.to_h["all"] == "all")
        player = response.match_data[:player].downcase if response.match_data[:player]
        versus = response.match_data[:versus].downcase if response.match_data[:versus]
        result = db.execute(<<-SQL, player, versus)
          SELECT rowid, * FROM matches WHERE
            (winner = IFNULL(?1, winner) AND loser = IFNULL(?2, loser)) OR
            (winner = IFNULL(?2, winner) AND loser = IFNULL(?1, loser))
          ORDER BY created_at DESC
          #{no_limit ? "" : "LIMIT 10"}
        SQL
        msg = result.map{|m| "#{m["rowid"]}: #{format_time(m["created_at"])} - #{obfuscate(m["winner"])} > #{obfuscate(m["loser"])}"}.join("\n")
        msg = "```#{msg}```"
        if result.empty?
          response.reply("no matches found")
        elsif no_limit && result.size > 10
          response.reply("(private reply)")
          response.reply_privately(msg)
        else
          response.reply(msg)
        end
      end

      def profile(response)
        from = response.match_data.to_h["from"] || "30day"
        name = response.match_data[:player].downcase
        player = get_player(name)
        board = get_leaderboard
        pos = (board.find_index{|l| l["player"] == name} || board.size) + 1
        stats = get_record(:player => name, :from => from).sort_by{|s| s["other"]}
        total = stats.shift || {"wins" => 0, "loses" => 0}
        desc = " (starter)" if player.starter?
        desc = " (pro)" if player.pro?
        response.reply("#{pos}. #{name} (#{player.rating})#{desc} #{total["wins"]}-#{total["loses"]} vs: " + stats.map{|s| "#{obfuscate(s["other"])} #{s["wins"]}-#{s["loses"]}"}.join("; "))
      end

      def versus(response)
        one = response.match_data[:one].downcase
        two = response.match_data[:two].downcase
        no_data = {"wins" => 0, "loses" => 0, "ratio" => "0.000"}
        total = get_record(:player => one, :versus => two).first || no_data
        week = get_record(:player => one, :versus => two, :from => "week").first || no_data
        month = get_record(:player => one, :versus => two, :from => "month").first || no_data
        one_points = winner_points(:winner => one, :loser => two)
        two_points = winner_points(:winner => two, :loser => one)
        response.reply("(#{one_points}) #{one} vs #{two} (#{two_points}): #{total["ratio"]}, week: #{week["wins"]}-#{week["loses"]}, month: #{month["wins"]}-#{month["loses"]}")
      end

      def leaderboard(response)
        from = response.match_data.to_h["from"]
        board = get_leaderboard(:from => from)
        return response.reply("no data from #{from}") if board.empty?
        board.each{|p| p["player"] << "*" if p["starter"]}
        response.reply(board.each_with_index.map{|p, i| "#{i + 1}. #{obfuscate(p["player"])} (#{p["rating"]}) #{p["wins"]}-#{p["loses"]}"}.join("\n"))
      end

      private

      # Returns an array like this:
      # [ {"player" => "jane", "other" => "jack", "rating" => "-",  "wins" => 1, "loses" => 2, "games_played" => 3, "ratio" => "0.333"}
      #   {"player" => "jane", "other" => "jill", "rating" => "-",  "wins" => 2, "loses" => 1, "games_played" => 3, "ratio" => "0.666"}
      #   {"player" => "jane", "other" => "-",    "rating" => 1200, "wins" => 3, "loses" => 3, "games_played" => 6, "ratio" => "0.500"} ]
      def get_record(player:nil, versus:nil, from:nil)
        db.execute(<<-SQL, player, versus, parse_date(from))
          SELECT player, other, "-" AS rating, SUM(loses) AS loses, SUM(wins) AS wins, "-" AS games_played,
            PRINTF("%.3f", SUM(wins) * 1.0 / (SUM(wins) + SUM(loses))) AS ratio
          FROM (
            SELECT winner AS player, loser AS other, count(*) AS wins, 0 AS loses FROM matches
            WHERE winner = ?1 AND loser = IFNULL(?2, loser) AND created_at > ?3 GROUP BY other
            UNION
            SELECT loser AS player, winner AS other, 0 AS wins, count(*) AS loses FROM matches
            WHERE loser = ?1 AND winner = IFNULL(?2, winner) AND created_at > ?3 GROUP BY other
          ) per_player
          JOIN players a_players ON a_players.name = per_player.other AND a_players.is_hidden = 0
          JOIN players b_players ON b_players.name = per_player.player AND b_players.is_hidden = 0
          GROUP BY other
          UNION
          SELECT player, "-" AS other, players.rating, SUM(loses) AS loses, SUM(wins) AS wins, players.games_played,
            PRINTF("%.3f", SUM(wins) * 1.0 / (SUM(wins) + SUM(loses))) AS ratio
          FROM (
            SELECT winner AS player, count(*) AS wins, 0 AS loses FROM matches
            WHERE winner = IFNULL(?1, winner) AND loser = IFNULL(?2, loser) AND created_at > ?3 GROUP BY player
            UNION
            SELECT loser AS player, 0 AS wins, count(*) AS loses FROM matches
            WHERE loser = IFNULL(?1, loser) AND winner = IFNULL(?2, winner) AND created_at > ?3 GROUP BY player
          ) total
          JOIN players ON players.name = total.player AND players.is_hidden = 0
          GROUP BY player
        SQL
      end

      def get_leaderboard(from:nil)
        from ||= "30day"
        stats = get_record(:from => from)
        stats.each do |st|
          player = Elo::Player.new(:games_played => st["games_played"])
          st["starter"] = player.starter?
        end
        stats.sort_by{|p| [(!p["starter"]).to_i, p["rating"]]}.reverse
      end

      def obfuscate(name)
        name.gsub(/^(.)/, '\1' + "\u200B")
      end

      def format_time(time)
        return nil unless time
        Time.parse(time).getlocal("-08:00").strftime("%a, %b %d")
      end

      def update_all
        db.execute("DELETE FROM players")
        db.execute("DELETE FROM player_histories")
        db.execute("SELECT * FROM matches").each do |match|
          update_players(:winner => match["winner"], :loser => match["loser"])
        end
      end

      def set_hidden(player:, hidden:)
        exists = db.execute("SELECT name FROM players WHERE name = ?", player).count == 1
        db.execute("UPDATE players SET is_hidden = ? WHERE name = ?", hidden.to_i, player) if exists
      end

      def parse_date(word)
        today = Time.now.getlocal("-08:00").to_date
        date = nil
        case word
        when "today"
          date = today
        when "week"
          date = Date.commercial(today.year, today.cweek, 1)
        when "month"
          date = Date.new(today.year, today.month, 1)
        when "7day"
          date = today - 7
        when "30day"
          date = today - 30
        else
          date = Date.new(2015)
        end
        Time.new(date.year, date.month, date.day, 0, 0, 0, "-08:00").utc.iso8601
      end

      def winner_points(winner:, loser:)
        rating = get_player(winner).wins_from(get_player(loser)).ratings.values.first
        format("%+d", (rating.new_rating - rating.old_rating))
      end

      def update_players(winner:, loser:)
        player = {
          winner => get_player(winner),
          loser => get_player(loser),
        }
        game = player[winner].wins_from(player[loser])
        time = Time.now.utc.iso8601
        player.each do |name, plyr|
          is_pro = (plyr.pro? || plyr.pro_rating?)
          db.execute("INSERT INTO player_histories (name, rating, created_at) VALUES (?, ?, ?)", name, plyr.rating, time)
          db.execute(<<-SQL, name, plyr.rating, is_pro.to_i, time)
            INSERT OR REPLACE INTO players (name, rating, games_played, is_pro, updated_at)
            VALUES(?1, ?2, IFNULL((SELECT games_played + 1 FROM players WHERE name = ?1), 1), ?3, ?4)
          SQL
        end
        game
      end

      def get_player(player)
        data = db.execute("SELECT * FROM players WHERE name = ?", player).first || {}
        Elo::Player.new("rating" => data["rating"], "games_played" => data["games_played"], "pro" => (data["is_pro"] == 1))
      end

      def db
        @db ||= begin
          Elo.configure do |elo|
            elo.default_rating = config.default_rating
            elo.pro_rating_boundry = config.pro_rating_boundry
            elo.starter_boundry = config.starter_boundry
          end

          db = SQLite3::Database.new(config.database)
          db.execute("CREATE TABLE IF NOT EXISTS matches (winner TEXT NOT NULL, loser TEXT NOT NULL, created_at TEXT NOT NULL)")
          db.execute("CREATE TABLE IF NOT EXISTS player_histories (name TEXT NOT NULL, rating INT NOT NULL, created_at TEXT NOT NULL)")
          db.execute(<<-SQL)
            CREATE TABLE IF NOT EXISTS players (
              name TEXT NOT NULL,
              rating INT NOT NULL,
              games_played INT NOT NULL,
              is_pro INT NOT NULL DEFAULT 0,
              is_hidden INT NOT NULL DEFAULT 0,
              updated_at TEXT NOT NULL,
              PRIMARY KEY(name)
            )
          SQL
          db.results_as_hash = true
          db
        end
      end
    end

    Lita.register_handler(Pong)
  end
end
