#!/bin/bash

# Default values
SECONDS_INACTIVE=60
PIXEL_MOVE=5

# Function to display help information
display_help() {
    echo "movemouse.sh"
    echo
    echo "Description:"
    echo "  Detects if the user has moved their mouse in the past X (default 60) seconds."
    echo "  If they have not, it will attempt to move the mouse."
    echo
    echo "Usage:"
    echo "  ./movemouse.sh [seconds=60] [pixels=5]"
    echo
    echo "Optional Arguments:"
    echo "  -h --help              Display help information"
    echo "  seconds=60             Time window to detect user activity"
    echo "  pixels=5               Number of pixels to move the mouse in the pattern"
    exit 0
}

# Parse command line arguments
for arg in "$@"; do
  case $arg in
    -h|--help)
      display_help
      ;;
    seconds=*)
      SECONDS_INACTIVE="${arg#*=}"
      shift
      ;;
    pixels=*)
      PIXEL_MOVE="${arg#*=}"
      shift
      ;;
    *)
      ;;
  esac
done

# Enable or disable logging
LOGGING=false

# Function to clean up background processes
cleanup() {
    echo "Cleaning up..."
    pkill -P $$
    exit 0
}

# Set trap to call cleanup on script exit
trap cleanup SIGINT SIGTERM

# Ensure only one instance of the script is running
current_pid=$$
for pid in $(pgrep -f 'movemouse.sh'); do
    if [ $pid -ne $current_pid ]; then
        echo "Killing previous instance of the script with PID $pid"
        kill $pid
    fi
done

# Function to find all devices with the capability pointer and exclude those with keyboard capability
find_pointer_devices() {
    sudo libinput list-devices | awk '
        /Device:/ { device="" }
        /Kernel:/ { device=$2 }
        /Capabilities:/ && /pointer/ && !/keyboard/ { if (device != "") print device }'
}

# Initial device list
device_paths=$(find_pointer_devices)

# Function to update device to move if it is disconnected
update_device_to_move() {
    device_paths=$(find_pointer_devices)
    if [ -n "$device_paths" ]; then
        device_to_move=$(echo "$device_paths" | head -n 1)
        echo "Updated moving mouse to device: $device_to_move"
    else
        device_to_move=""
        echo "No pointer devices found."
    fi
}

# Choose one device to move (the first one in the list)
device_to_move=$(echo "$device_paths" | head -n 1)

echo "Monitoring devices:"
echo "$device_paths"
echo "Moving mouse on device: $device_to_move"

# Store the last event time in a file
last_event_file="/tmp/last_event_time"
echo $(date +%s) > $last_event_file

# Function to move the mouse
move_mouse() {
    echo "No activity detected for $SECONDS_INACTIVE seconds. Moving the mouse..."
    local movements=(
        "0 -${PIXEL_MOVE}"                 # Move up
        "${PIXEL_MOVE} ${PIXEL_MOVE}"      # Move down and right
        "-${PIXEL_MOVE} ${PIXEL_MOVE}"     # Move left and down
        "-${PIXEL_MOVE} -${PIXEL_MOVE}"    # Move up and left
        "${PIXEL_MOVE} -${PIXEL_MOVE}"     # Move right and up
        "0 ${PIXEL_MOVE}"                  # Move down (back to center)
    )

    for movement in "${movements[@]}"; do
        x_value=$(echo $movement | awk '{print $1}')
        y_value=$(echo $movement | awk '{print $2}')
        if $LOGGING; then
            echo "Moving to X: $x_value, Y: $y_value"
        fi
        if [ -e "$device_to_move" ]; then
            if [[ -n $x_value && -n $y_value ]]; then
                sudo /usr/bin/evemu-event ${device_to_move} --type EV_REL --code REL_X --value $x_value --sync
                sudo /usr/bin/evemu-event ${device_to_move} --type EV_REL --code REL_Y --value $y_value --sync
            else
                echo "Invalid coordinates: X: $x_value, Y: $y_value"
            fi
        else
            echo "Device $device_to_move not found. Updating device..."
            update_device_to_move
            if [ -z "$device_to_move" ]; then
                echo "No devices found, switching to xdotool."
                for movement in "${movements[@]}"; do
                    x_value=$(echo $movement | awk '{print $1}')
                    y_value=$(echo $movement | awk '{print $2}')
                    if $LOGGING; then
                        echo "Moving to X: $x_value, Y: $y_value"
                    fi
                    xdotool mousemove_relative -- $x_value $y_value
                done
                return
            fi
        fi
    done
}

# Monitor mouse events for all pointer devices
for device in $device_paths; do
    sudo libinput debug-events --device "$device" | while read -r line; do
        current_time=$(date +%s)

        # Log the full output of $line if logging is enabled
        if $LOGGING; then
            echo "Event: $line"
        fi

        # Extract coordinates from pointer motion events
        if echo "$line" | grep -q "POINTER_MOTION"; then
            coords=$(echo "$line" | awk -F '[()]' '{print $2}')
            if [ -n "$coords" ]; then
                if $LOGGING; then
                    echo "Extracted coords: $coords"
                fi
                x_value=$(echo $coords | awk -F '/' '{print $1}' | xargs)
                y_value=$(echo $coords | awk -F '/' '{print $2}' | xargs)
                if $LOGGING; then
                    echo "Parsed Delta X: $x_value, Parsed Delta Y: $y_value"
                    echo "Delta X: $x_value, Delta Y: $y_value"
                fi

                echo $current_time > $last_event_file
            else
                if $LOGGING; then
                    echo "Failed to match coordinates with regex in line: $line"
                fi
            fi
        fi
    done &
done

# Background timer to check inactivity
(
    while true; do
        sleep "$SECONDS_INACTIVE"
        current_time=$(date +%s)
        last_event_time=$(cat $last_event_file)
        elapsed_time=$((current_time - last_event_time))

        if [ "$elapsed_time" -ge "$SECONDS_INACTIVE" ]; then
            move_mouse
            echo $(date +%s) > $last_event_file  # Update the last event time
        fi
    done
) &

# Keep the script running to capture events
wait
EOF

chmod +x movemouse.sh
