#!/bin/zsh

set -u

script_dir="${0:A:h}"
renderer_script="$script_dir/render_glb.py"
blender_candidates=(
  "/Applications/Blender 5.2 LTS.app/Contents/MacOS/Blender"
  "/Applications/Blender.app/Contents/MacOS/Blender"
)

blender_bin=""
for candidate in "${blender_candidates[@]}"; do
  if [[ -x "$candidate" ]]; then
    blender_bin="$candidate"
    break
  fi
done

if [[ -z "$blender_bin" ]]; then
  print -u2 "Blender 5.2 LTS was not found in /Applications."
  print -u2 "Download the Apple Silicon LTS build from https://www.blender.org/download/lts/"
  read -r "?Press Return to close."
  exit 1
fi

input_files=("$@")
if (( ${#input_files} == 0 )); then
  selection="$(osascript <<'APPLESCRIPT'
try
  set pickedFiles to choose file with prompt "Choose GLB or Drop & View render packages" with multiple selections allowed
  set selectedPaths to ""
  repeat with pickedFile in pickedFiles
    set selectedPaths to selectedPaths & POSIX path of pickedFile & linefeed
  end repeat
  return selectedPaths
on error number -128
  return ""
end try
APPLESCRIPT
)"
  input_files=("${(@f)selection}")
  if (( ${#input_files} == 0 )); then
    exit 0
  fi
fi

bridge_exit_code=0
last_output_file=""
for input_file in "${input_files[@]}"; do
  extension="${input_file:e:l}"
  if [[ ! -f "$input_file" || ( "$extension" != "glb" && "$extension" != "dvrender" ) ]]; then
    print -u2 "Skipped (not a GLB or .dvrender): $input_file"
    bridge_exit_code=1
    continue
  fi
  if "$blender_bin" \
      --background \
      --factory-startup \
      --python-exit-code 1 \
      --python "$renderer_script" \
      -- "$input_file"; then
    output_file="${input_file:r}-cycles.png"
    if [[ -f "$output_file" ]]; then
      last_output_file="$output_file"
    else
      print -u2 "Render finished, but its output could not be found: $output_file"
      bridge_exit_code=1
    fi
  else
    bridge_exit_code=1
  fi
done

if [[ -n "$last_output_file" ]]; then
  open -R "$last_output_file"
fi

if (( bridge_exit_code != 0 )); then
  print -u2 "One or more renders failed."
  read -r "?Press Return to close."
fi
exit $bridge_exit_code
