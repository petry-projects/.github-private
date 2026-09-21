# Benign prompt fixture

The heading detector must ignore `#`-prefixed lines inside fenced code blocks —
otherwise a shell comment in an example would masquerade as a duplicate heading.

## Real heading

```bash
# Phase 2 — Fix
echo "not a heading"
# Phase 2 — Fix
echo "still not a heading"
```

## Another real heading

```
# Phase 2 — Fix
```
