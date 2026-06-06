#!/bin/bash
export $(grep -v '^#' /etc/variable | xargs)
source /srv/venvs/early/bin/activate
cd /srv/treehole
exec python3 app.py
