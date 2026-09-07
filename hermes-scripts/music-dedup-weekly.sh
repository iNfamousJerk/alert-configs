#!/bin/bash
# Weekly Music Dedup - runs on CT110 media-stack
# Silent if clean, reports deletions if any.
# Designed to be run as a no_agent cron job.

MEDIA_HOST="root@10.0.1.8"
DEDUP_SCRIPT="/root/music-dedup.py"
SSH_CMD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 $MEDIA_HOST"

# Run the dedup with --delete, capture output
OUTPUT=$($SSH_CMD "cd /root && python3 $DEDUP_SCRIPT --delete" 2>&1)
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
    echo "⚠️ Music Dedup failed (exit $EXIT_CODE):"
    echo "$OUTPUT"
    exit 1
fi

# Extract key lines - only show if there were actual deletions
DELETED=$(echo "$OUTPUT" | grep -oP 'Deleted \d+|DupGroups: \d+' | tail -1)
SAVED=$(echo "$OUTPUT" | grep -oP 'freed \d+MB')

if [ -z "$DELETED" ] || [ "$DELETED" = "DupGroups: 0" ]; then
    # Silent exit - nothing to report
    exit 0
fi

# Check if any files were actually deleted
DEL_COUNT=$(echo "$OUTPUT" | grep -c "^  DEL:")
if [ "$DEL_COUNT" -eq 0 ]; then
    # No deletions happened - silent
    exit 0
fi

# Report deletions
echo "🎵 Music Dedup Complete"
echo "$OUTPUT" | grep -E "^(Scanned:|Deleted |Delet |Artist=|  DEL:|DupGroups:|Clean!|freed)"
echo ""
echo "Total files removed: $DEL_COUNT"
echo "$SAVED"
