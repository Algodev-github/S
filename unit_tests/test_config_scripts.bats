#!/usr/bin/env bats

cd $BATS_TEST_DIRNAME

# must be fully qualified (absolute) path in order to specify the .sh extension
load $BATS_TEST_DIRNAME/../config_params.sh

load prev_impl

@test "compare find_partition_for_dir implementations" {
  # original implementation
  run original_find_partition_for_dir "$(pwd)"
  original_output=$output

  # modified original implementation
  run original_find_partition_for_dir "$(pwd)" "allow no slash in partition"
  modified_output=$output

  # current implementation
  run find_partition_for_dir "$(pwd)"
  current_output=$output

  [ "$current_output" = "$original_output" ] || [ "$current_output" = "$modified_output" ]
}

@test "test find_dev_for_dir" {
  run find_dev_for_dir "$(pwd)"

  # Echo and other stdout are limited to error cases in find_dev_for_dir
  # so one way to verify success is to assert empty output.
  # We could change this to [ "$status" -eq 0 ] if we add nonzero exit codes.
  [ "$output" = "" ]
}

@test "test get_partition_info" {
  run find_partition_for_dir "$(pwd)"
  part="$output"

  run get_partition_info "$part"
  part_info="$output"

  [ -n "$part_info" ]

  # we could change this to wc --lines, but grep is more commonly available
  line_count=$(echo "$part_info" | grep -c '')
  [ "$line_count" -eq 1 ]

  free_space=$(echo "$part_info" | awk '{print $4}')
  [ -n "$free_space" ]

  # assert is number
  echo $free_space | grep -E -q "^[0-9]+$"
}
