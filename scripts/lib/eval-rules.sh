#!/usr/bin/env bash
# Thymus shared rule evaluation logic
# Source this file after common.sh

[[ -n "${_THYMUS_EVAL_RULES_LOADED:-}" ]] && return 0
_THYMUS_EVAL_RULES_LOADED=1

# Check if a source file has a colocated test file
# Returns 0 (has test) or 1 (missing test)
# Args: abs_path rel_path
check_test_colocation() {
  local abs_path="$1" rel_path="$2"

  # Skip test files themselves, type definition files
  [[ "$rel_path" =~ \.(ts|js|py|java|go|rs|dart|kt|kts|swift|cs|php|rb)$ ]] || return 0
  [[ "$rel_path" =~ \.(test|spec)\. ]] && return 0
  [[ "$rel_path" =~ \.d\.ts$ ]] && return 0
  [[ "$rel_path" =~ (Test|Tests|IT|Spec)\.java$ ]] && return 0
  [[ "$rel_path" =~ _test\.(go|dart|rb)$ ]] && return 0
  [[ "$rel_path" =~ _spec\.rb$ ]] && return 0
  [[ "$rel_path" =~ (Test|Tests)\.kt$ ]] && return 0
  [[ "$rel_path" =~ (Tests)\.swift$ ]] && return 0
  [[ "$rel_path" =~ (Tests|Test)\.cs$ ]] && return 0
  [[ "$rel_path" =~ (Test)\.php$ ]] && return 0

  local base="${abs_path%.*}"
  local ext="${abs_path##*.}"

  # Generic: foo.test.ext or foo.spec.ext
  if [ -f "${base}.test.${ext}" ] || [ -f "${base}.spec.${ext}" ]; then
    return 0
  fi

  local basename_no_ext dir
  basename_no_ext=$(basename "${base}")
  dir=$(dirname "${abs_path}")

  case "$ext" in
    java)
      [ -f "${dir}/${basename_no_ext}Test.java" ] || \
      [ -f "${dir}/${basename_no_ext}Tests.java" ] || \
      [ -f "${dir}/${basename_no_ext}IT.java" ] && return 0
      if [[ "$abs_path" == *"/src/main/java/"* ]]; then
        local test_mirror_base
        test_mirror_base="$(echo "$abs_path" | sed 's|src/main/java|src/test/java|')"
        test_mirror_base="${test_mirror_base%.*}"
        [ -f "${test_mirror_base}Test.java" ] || \
        [ -f "${test_mirror_base}Tests.java" ] || \
        [ -f "${test_mirror_base}IT.java" ] && return 0
      fi
      ;;
    go)
      local test_name="${abs_path%.go}"
      test_name="$(basename "${test_name}")_test.go"
      [ -f "${dir}/${test_name}" ] && return 0
      ;;
    rs)
      grep -q '#\[cfg(test)\]' "${abs_path}" 2>/dev/null && return 0
      [ -f "$PWD/tests/${basename_no_ext}.rs" ] || \
      [ -f "$PWD/tests/test_${basename_no_ext}.rs" ] && return 0
      ;;
    dart)
      [ -f "${dir}/${basename_no_ext}_test.dart" ] && return 0
      if [[ "$abs_path" == *"/lib/"* ]]; then
        local test_mirror_base
        test_mirror_base="$(echo "$abs_path" | sed 's|/lib/|/test/|')"
        test_mirror_base="${test_mirror_base%.*}"
        [ -f "${test_mirror_base}_test.dart" ] && return 0
      fi
      ;;
    kt|kts)
      [ -f "${dir}/${basename_no_ext}Test.kt" ] || \
      [ -f "${dir}/${basename_no_ext}Tests.kt" ] && return 0
      if [[ "$abs_path" == *"/src/main/"* ]]; then
        local test_mirror_base
        test_mirror_base="$(echo "$abs_path" | sed 's|src/main/kotlin|src/test/kotlin|' | sed 's|src/main/java|src/test/java|')"
        test_mirror_base="${test_mirror_base%.*}"
        [ -f "${test_mirror_base}Test.kt" ] || \
        [ -f "${test_mirror_base}Tests.kt" ] && return 0
      fi
      ;;
    swift)
      [ -f "${dir}/${basename_no_ext}Tests.swift" ] && return 0
      if [[ "$abs_path" == *"/Sources/"* ]]; then
        local test_mirror_base
        test_mirror_base="$(echo "$abs_path" | sed 's|/Sources/|/Tests/|')"
        test_mirror_base="${test_mirror_base%.*}"
        [ -f "${test_mirror_base}Tests.swift" ] && return 0
      fi
      ;;
    cs)
      [ -f "${dir}/${basename_no_ext}Tests.cs" ] || \
      [ -f "${dir}/${basename_no_ext}Test.cs" ] && return 0
      ;;
    php)
      [ -f "${dir}/${basename_no_ext}Test.php" ] && return 0
      if [[ "$abs_path" == *"/src/"* ]]; then
        local test_mirror_base
        test_mirror_base="$(echo "$abs_path" | sed 's|/src/|/tests/|')"
        test_mirror_base="${test_mirror_base%.*}"
        [ -f "${test_mirror_base}Test.php" ] && return 0
      fi
      ;;
    rb)
      [ -f "${dir}/${basename_no_ext}_test.rb" ] || \
      [ -f "${dir}/${basename_no_ext}_spec.rb" ] && return 0
      if [[ "$abs_path" == *"/app/"* ]]; then
        local test_mirror_base spec_mirror_base
        test_mirror_base="$(echo "$abs_path" | sed 's|/app/|/test/|')"
        spec_mirror_base="$(echo "$abs_path" | sed 's|/app/|/spec/|')"
        test_mirror_base="${test_mirror_base%.*}"
        spec_mirror_base="${spec_mirror_base%.*}"
        [ -f "${test_mirror_base}_test.rb" ] || \
        [ -f "${spec_mirror_base}_spec.rb" ] && return 0
      fi
      ;;
  esac

  return 1  # no test found
}

# Evaluate a single invariant against a file. Outputs violation JSON objects (one per line) to stdout.
# Args: abs_path rel_path invariant_json
# Returns: 0 always (violations go to stdout)
eval_rule_for_file() {
  local abs_path="$1" rel_path="$2" inv="$3"
  local rule_id rule_type severity description

  rule_id=$(echo "$inv" | jq -r '.id')
  rule_type=$(echo "$inv" | jq -r '.type')
  severity=$(echo "$inv" | jq -r '.severity')
  description=$(echo "$inv" | jq -r '.description')

  file_in_scope "$rel_path" "$inv" || return 0
  [ -f "$abs_path" ] || return 0

  case "$rule_type" in
    boundary)
      local imports
      imports=$(extract_imports "$abs_path")
      [ -z "$imports" ] && return 0
      while IFS= read -r import; do
        [ -z "$import" ] && continue
        if import_is_forbidden "$import" "$inv"; then
          jq -cn \
            --arg rule "$rule_id" --arg sev "$severity" --arg msg "$description" \
            --arg file "$rel_path" --arg imp "$import" \
            '{rule:$rule,severity:$sev,message:$msg,file:$file,import:$imp}'
        fi
      done <<< "$imports"
      ;;

    pattern)
      local forbidden_pattern
      forbidden_pattern=$(echo "$inv" | jq -r '.forbidden_pattern // empty')
      [ -z "$forbidden_pattern" ] && return 0
      if grep -qE "$forbidden_pattern" "$abs_path" 2>/dev/null; then
        local line_num
        line_num=$({ grep -nE "$forbidden_pattern" "$abs_path" 2>/dev/null | head -1 | cut -d: -f1; } || echo "")
        jq -cn \
          --arg rule "$rule_id" --arg sev "$severity" --arg msg "$description" \
          --arg file "$rel_path" --arg line "${line_num}" \
          '{rule:$rule,severity:$sev,message:$msg,file:$file,line:$line}'
      fi
      ;;

    convention)
      local rule_text
      rule_text=$(echo "$inv" | jq -r '.rule // empty')
      if echo "$rule_text" | grep -qi "test"; then
        if ! check_test_colocation "$abs_path" "$rel_path"; then
          jq -cn \
            --arg rule "$rule_id" --arg sev "$severity" \
            --arg msg "missing colocated test file" --arg file "$rel_path" \
            '{rule:$rule,severity:$sev,message:$msg,file:$file}'
        fi
      fi
      ;;

    dependency)
      local package
      package=$(echo "$inv" | jq -r '.package // empty')
      [ -z "$package" ] && return 0
      local allowed_count in_allowed
      allowed_count=$(echo "$inv" | jq 'if .allowed_in then .allowed_in | length else 0 end' 2>/dev/null || echo 0)
      in_allowed=false
      for ((a=0; a<allowed_count; a++)); do
        local allowed_glob
        allowed_glob=$(echo "$inv" | jq -r ".allowed_in[$a]")
        if path_matches "$rel_path" "$allowed_glob"; then
          in_allowed=true; break
        fi
      done
      $in_allowed && return 0
      local file_imports
      file_imports=$(extract_imports "$abs_path")
      if echo "$file_imports" | grep -qF "$package" 2>/dev/null; then
        jq -cn \
          --arg rule "$rule_id" --arg sev "$severity" --arg msg "$description" \
          --arg file "$rel_path" --arg pkg "$package" \
          '{rule:$rule,severity:$sev,message:$msg,file:$file,package:$pkg}'
      fi
      ;;
  esac
}
