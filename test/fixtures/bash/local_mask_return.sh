#!/bin/bash
foo() {
  local x=$(cmd)
  local y=$(grep -c foo bar)
  export z=$(date)
  local plain="hello"
  local num=42
}
