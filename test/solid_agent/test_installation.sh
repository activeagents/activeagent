#!/bin/bash

# region install
bundle install
rails generate solid_agent:install
rails db:migrate
# endregion install