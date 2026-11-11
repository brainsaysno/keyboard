#!/bin/bash

# @raycast.schemaVersion 1
# @raycast.title Headphones Noise Cancellation
# @raycast.mode silent
# @raycast.packageName Headphones
# @raycast.description Switch connected AirPods or Sony headphones to noise cancellation (Corne: Raise+X sends F19)

exec "$HOME/.local/bin/headphones-mode" noise-cancellation
