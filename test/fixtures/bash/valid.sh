#!/bin/bash
echo "hello world"
cd /tmp || exit 1
name="test"
echo "$name"
files="$(ls -la)"
echo "$files"
