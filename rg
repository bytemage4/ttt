`ripgrep` approaches to find customized `DefaultErrorHandler` usage:

## **1. Basic Search with Context**

```bash
# Search all projects, showing 5 lines of context
rg "DefaultErrorHandler" -A 5 -B 2 --type java
```

## **2. Find Customization Method Calls**

```bash
# Find projects using customization methods
rg "(addNotRetryableExceptions|addRetryableExceptions|setClassifications|setBackOffFunction|setRetryListeners|DeadLetterPublishingRecoverer)" --type java -l

# Show the actual code
rg "(addNotRetryableExceptions|addRetryableExceptions|setClassifications|setBackOffFunction|setRetryListeners|DeadLetterPublishingRecoverer)" --type java -C 3
```

## **3. Find Non-Default Constructors**

```bash
# Find DefaultErrorHandler with custom recoverer or backoff (has parameters)
rg "new DefaultErrorHandler\([^)]+\)" --type java -C 2
```

## **4. Per-Project Summary**

```bash
# List which projects use DefaultErrorHandler at all
rg "DefaultErrorHandler" --type java --files-with-matches | \
  awk -F/ '{print $1}' | sort -u

# Or get counts per project
rg "DefaultErrorHandler" --type java --files-with-matches | \
  awk -F/ '{print $1}' | sort | uniq -c
```

## **5. Comprehensive Search for Customizations**

```bash
# Find any DefaultErrorHandler followed by method chaining or variable usage
rg "DefaultErrorHandler.*(\{|;|\.)|(errorHandler|handler)\.(add|set)" --type java -C 5
```

## **6. Interactive Selection (with fzf if installed)**

```bash
# Browse through all DefaultErrorHandler usages interactively
rg "DefaultErrorHandler" --type java -C 3 | fzf
```

## **7. Generate Report**

```bash
# Create a summary report
for dir in */; do
  if rg -q "DefaultErrorHandler" "$dir" --type java; then
    echo "=== $dir ==="
    rg "DefaultErrorHandler" "$dir" --type java -C 2
    echo ""
  fi
done
```

## **8. My Recommended Command**

```bash
# Find customized usage (exclude simple "new DefaultErrorHandler()")
rg "DefaultErrorHandler" --type java -C 3 | \
  rg -v "new DefaultErrorHandler\(\s*\)" -C 3
```

Or more specifically for customizations:

```bash
# Show only files with actual customization methods
rg -l "DefaultErrorHandler" --type java | \
  xargs rg "(addNotRetryable|addRetryable|setClassifications|setBackOff|setRetryListeners|DeadLetterPublishingRecoverer|ConsumerRecordRecoverer)" -C 5
```

## **9. Exclude Test Files**

```bash
# Skip test directories
rg "DefaultErrorHandler" --type java -g '!*test*' -g '!*Test*' -C 3
```

## **10. Combine with Project Name**

```bash
# Show project name with each match
rg "DefaultErrorHandler" --type java -C 2 --heading --color always | \
  awk '/^[^:]+$/{project=$0} /DefaultErrorHandler/{print project": "$0}'
```

**For your use case, I'd recommend:**

```bash
# Quick overview - which projects customize it
rg "(addNotRetryableExceptions|addRetryableExceptions|setClassifications|DeadLetterPublishingRecoverer)" \
  --type java -l | awk -F/ '{print $1}' | sort -u

# Detailed view - see the actual customizations
rg "DefaultErrorHandler" --type java -C 5 | \
  rg "(addNotRetryable|addRetryable|setClassifications|setBackOff|setRetryListeners|new DefaultErrorHandler\([^)]+\))" -C 5
```

This will show you which projects are actually configuring `DefaultErrorHandler` beyond the defaults!
