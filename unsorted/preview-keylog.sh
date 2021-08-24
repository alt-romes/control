#!/bin/bash
cat keystroke.log | perl -pe 's|\[.*?\]||g' | tr " " "\n" | tail
