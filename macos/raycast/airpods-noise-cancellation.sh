#!/bin/bash

# @raycast.schemaVersion 1
# @raycast.title AirPods Noise Cancellation
# @raycast.mode silent
# @raycast.packageName AirPods
# @raycast.description Switch the connected AirPods to Noise Cancellation (Corne: Raise+X sends F19)

exec "$HOME/.local/bin/airpods-mode" noise-cancellation
