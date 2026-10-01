# Fix paging bug

## Captain's intent

Fix the known off-by-one bug in the pager so one page is returned per call.

## Firstmate spec

The root cause is the less-than-or-equal comparison in the page boundary check. Implement the correction and verify the regression.
