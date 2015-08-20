# lita-pong

A lita plugin for tracking Elo ranking of ping-pong players.

## Installation

Add lita-pong to your Lita instance's Gemfile:

``` ruby
gem "lita-pong", :git => "https://github.com/kcrayon/lita-pong.git"
```

## Configuration

Add the following variables to your Lita config file:

``` ruby
config.handlers.pong.default_rating = 1000
config.handlers.pong.pro_rating_boundry = 1200
config.handlers.pong.starter_boundry = 15
config.handlers.pong.database = "/var/tmp/pong.db"
```


## Usage

### Recording a match
```
pong <winner_name> beat <loser_name>    - Record who won a match
```

### Showing the leaderboard
```
pong leaderboard                        - Show the leaderboard
```

### Player profiles and stats
```
pong player <name>                      - Show information about specific player
pong <name> vs <other>                  - Show matchup details between two players
```

### Match listings
```
pong (all) matches <name>               - Show recent matches for specific player
pong (all) matches <name> vs <other>    - Show recent matches between two players
```

### Admin commands
```
pong admin delete-match <id>            - Delete a recorded match, useful if you've typo'd a name
pong admin update-all                   - Recalculate all the scores, useful if you've changed settings
pong admin hide-player <name>           - Hide a player from the leaderboard and most other lists
pong admin unhide-player <name>         - Unhide a player
```
