#!/bin/bash
echo "    skip: CI checks still in progress for $1"
echo '{"pr":"'"$1"'","decision":"skip","reason":"ci-pending"}'
exit 100
