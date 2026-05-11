#!/usr/bin/env bash
set -u
set -o pipefail

# ============================================================
# PDF -> Markdown Extractor
# Multi-core + OCR + Cleaning + Cross-distro Linux support
# ============================================================
#
# DESCRIPTION
# -----------
# This script processes a large PDF dataset and generates cleaned
# Markdown files using the following pipeline:
#
#   1) Native text extraction with pdftotext
#   2) Forced OCR fallback with ocrmypdf when needed
#   3) Markdown-oriented text cleaning
#   4) Parallel processing (multi-core)
#   5) Real-time progress display
#   6) Per-file status logs + global stats
#
# FEATURES
# --------
# - Works on Ubuntu / Debian
# - Works on CentOS / RHEL / Rocky / AlmaLinux / Fedora
# - Parallel processing (JOBS=4 by default)
# - Handles scanned PDFs and broken text layers
# - Adds light classification in output filenames:
#     __native_text.md
#     __ocr_forced.md
#     __mixed.md
#     __low_quality.md
# - Generates logs and dataset statistics
# - Uses short hashed temp filenames to avoid "File name too long"
#
# USAGE
# -----
#   chmod +x convert_pdf_dataset.sh
#   ./convert_pdf_dataset.sh
#
# EXAMPLES
# --------
#   ./convert_pdf_dataset.sh
#   INPUT_DIR="./pdfs" JOBS=4 ./convert_pdf_dataset.sh
#   INPUT_DIR="./pdfs" OUTPUT_DIR="./out_md" LOG_DIR="./logs" ./convert_pdf_dataset.sh
#
# ENV VARIABLES
# -------------
#   INPUT_DIR        Source directory containing PDFs
#   OUTPUT_DIR       Output directory for Markdown files
#   LOG_DIR          Logs directory
#   JOBS             Number of parallel workers (default: 4)
#   TIMEOUT_SECONDS  Max processing time per PDF (default: 180)
#   MIN_TEXT_CHARS   Minimum alnum chars to validate extraction (default: 40)
#   OCR_LANGS        OCR languages for tesseract (default: fra+eng)
#   INSTALL_DEPS     auto | yes | no  (default: auto)
#
# ============================================================


# =========================
# CONFIGURATION
# =========================

INPUT_DIR="${INPUT_DIR:-.}"
OUTPUT_DIR="${OUTPUT_DIR:-output_md}"
LOG_DIR="${LOG_DIR:-logs}"

JOBS="${JOBS:-4}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-180}"
MIN_TEXT_CHARS="${MIN_TEXT_CHARS:-40}"
OCR_LANGS="${OCR_LANGS:-fra+eng}"
INSTALL_DEPS="${INSTALL_DEPS:-auto}"

PER_FILE_LOG_DIR="$LOG_DIR/per_file"
TMP_DIR="$LOG_DIR/tmp"

SUCCESS_LOG="$LOG_DIR/success.log"
OCR_LOG="$LOG_DIR/ocr.log"
FAILED_LOG="$LOG_DIR/failed.log"
SKIPPED_LOG="$LOG_DIR/skipped.log"
ERROR_LOG="$LOG_DIR/errors.log"
STATS_GLOBAL_LOG="$LOG_DIR/stats_global.log"

PROGRESS_PID=""


# =========================
# CLEAN EXIT / INTERRUPT
# =========================

cleanup_on_exit() {
    local exit_code=$?

    if [ -n "${PROGRESS_PID:-}" ] && kill -0 "$PROGRESS_PID" >/dev/null 2>&1; then
        kill "$PROGRESS_PID" >/dev/null 2>&1 || true
        wait "$PROGRESS_PID" 2>/dev/null || true
    fi

    return "$exit_code"
}

trap cleanup_on_exit EXIT
trap 'echo; echo "Interrupted by user."; exit 130' INT TERM


# =========================
# BASIC HELPERS
# =========================

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

make_short_id() {
    local input="$1"

    if command_exists sha1sum; then
        printf '%s' "$input" | sha1sum | awk '{print substr($1,1,16)}'
    elif command_exists shasum; then
        printf '%s' "$input" | shasum | awk '{print substr($1,1,16)}'
    else
        # very unlikely on Linux, but keep a fallback
        printf '%s' "$input" | cksum | awk '{print $1}'
    fi
}

count_alnum_chars() {
    local file="$1"
    tr -cd '[:alnum:]' < "$file" | wc -c | tr -d ' '
}

count_words() {
    local file="$1"
    wc -w < "$file" | tr -d ' '
}

is_valid_text() {
    local file="$1"

    if [ ! -s "$file" ]; then
        return 1
    fi

    local count
    count=$(count_alnum_chars "$file")

    if [ "$count" -lt "$MIN_TEXT_CHARS" ]; then
        return 1
    fi

    return 0
}

safe_relpath() {
    local f="$1"
    local rel

    rel="${f#"$INPUT_DIR"/}"
    rel="${rel#./}"

    echo "$rel"
}

make_output_base() {
    local rel="$1"
    echo "$OUTPUT_DIR/${rel%.pdf}"
}


# =========================
# OS / PACKAGE MANAGER DETECTION
# =========================

detect_pkg_manager() {
    if command_exists apt-get; then
        echo "apt"
        return
    fi

    if command_exists dnf; then
        echo "dnf"
        return
    fi

    if command_exists yum; then
        echo "yum"
        return
    fi

    echo "unknown"
}

install_if_missing_apt() {
    local pkg="$1"
    dpkg -s "$pkg" >/dev/null 2>&1 || sudo apt-get install -y "$pkg"
}

install_if_missing_rpm() {
    local pkg="$1"
    if command_exists rpm; then
        rpm -q "$pkg" >/dev/null 2>&1 || {
            if command_exists dnf; then
                sudo dnf install -y "$pkg"
            else
                sudo yum install -y "$pkg"
            fi
        }
    else
        if command_exists dnf; then
            sudo dnf install -y "$pkg"
        else
            sudo yum install -y "$pkg"
        fi
    fi
}

check_dependencies_only() {
    local missing=0

    for cmd in pdftotext pdfinfo ocrmypdf tesseract timeout xargs awk sed find; do
        if ! command_exists "$cmd"; then
            echo "Missing command: $cmd"
            missing=1
        fi
    done

    return "$missing"
}

install_dependencies() {
    local pm
    pm="$(detect_pkg_manager)"

    echo "=== Checking system dependencies ==="

    # If dependencies are already installed, continue immediately.
    if check_dependencies_only; then
        echo "Dependencies already installed."
        return 0
    fi

    # Respect explicit non-install mode.
    if [ "$INSTALL_DEPS" = "no" ]; then
        echo
        echo "Some required dependencies are missing."
        echo "Automatic installation is disabled because INSTALL_DEPS=no."
        echo "Please install the required packages manually and rerun the script."
        exit 1
    fi

    # Unsupported package manager.
    if [ "$pm" = "unknown" ]; then
        echo
        echo "Unsupported package manager."
        echo "Please install manually:"
        echo "  - poppler-utils (provides pdftotext and pdfinfo)"
        echo "  - ocrmypdf"
        echo "  - tesseract"
        echo "  - language packs for: $OCR_LANGS"
        exit 1
    fi

    # Inform the user before requesting sudo.
    echo
    echo "The following commands are missing:"
    check_dependencies_only || true

    echo
    echo "Required packages to install:"
    case "$pm" in
        apt)
            echo "  - poppler-utils"
            echo "  - ocrmypdf"
            echo "  - tesseract-ocr"
            echo "  - tesseract-ocr-eng"
            echo "  - tesseract-ocr-fra"
            echo
            echo "Manual installation commands:"
            echo "  sudo apt-get update"
            echo "  sudo apt-get install -y poppler-utils ocrmypdf tesseract-ocr tesseract-ocr-eng tesseract-ocr-fra"
            ;;
        dnf|yum)
            echo "  - poppler-utils"
            echo "  - ocrmypdf"
            echo "  - tesseract"
            echo
            echo "Manual installation commands:"
            if [ "$pm" = "dnf" ]; then
                echo "  sudo dnf install -y poppler-utils ocrmypdf tesseract"
            else
                echo "  sudo yum install -y poppler-utils ocrmypdf tesseract"
            fi
            ;;
    esac

    echo
    echo "Choose how you want to proceed:"
    echo "  1) I will install the packages myself and rerun the script"
    echo "  2) Let the script install them automatically using sudo"
    echo "  3) Cancel"
    echo

    read -rp "Choose an option [1-3]: " choice

    case "$choice" in
        1)
            echo
            echo "Please install the packages using the commands above, then rerun the script."
            exit 1
            ;;
        2)
            echo
            echo "Installing missing dependencies..."

            case "$pm" in
                apt)
                    sudo apt-get update
                    install_if_missing_apt poppler-utils
                    install_if_missing_apt ocrmypdf
                    install_if_missing_apt tesseract-ocr
                    install_if_missing_apt tesseract-ocr-eng
                    install_if_missing_apt tesseract-ocr-fra
                    ;;
                dnf|yum)
                    if [ "$pm" = "dnf" ]; then
                        sudo dnf makecache -y
                    else
                        sudo yum makecache -y
                    fi

                    install_if_missing_rpm poppler-utils
                    install_if_missing_rpm ocrmypdf
                    install_if_missing_rpm tesseract
                    install_if_missing_rpm tesseract-langpack-eng || true
                    install_if_missing_rpm tesseract-langpack-fra || true
                    ;;
            esac
            ;;
        *)
            echo
            echo "Installation cancelled."
            exit 1
            ;;
    esac

    # Final verification.
    if check_dependencies_only; then
        echo "=== Dependencies OK ==="
    else
        echo "Dependency installation completed, but some required commands are still missing."
        echo "Please install them manually and rerun."
        exit 1
    fi
}

# =========================
# MARKDOWN CLEANING
# =========================

clean_markdown() {
    local input_file="$1"
    local output_file="$2"

    awk '
    function ltrim(s) { sub(/^[ \t\r\n]+/, "", s); return s }
    function rtrim(s) { sub(/[ \t\r\n]+$/, "", s); return s }
    function trim(s)  { return rtrim(ltrim(s)) }

    function is_all_caps(s,    t) {
        t = s
        gsub(/[^A-Za-z]/, "", t)
        if (length(t) == 0) return 0
        return (t == toupper(t))
    }

    function is_noise_line(s,    t, alnum, total) {
        t = s
        total = length(t)
        gsub(/[[:alnum:]]/, "", t)
        alnum = total - length(t)

        if (length(s) < 2) return 1
        if (total > 0 && alnum < 2 && total < 8) return 1

        return 0
    }

    function looks_like_heading(s,    len) {
        len = length(s)

        if (len >= 4 && len <= 80) {
            if (is_all_caps(s)) return 1
            if (s ~ /^[A-Z][A-Za-z0-9()\/:+ -]+$/ && s !~ /[.;]$/) return 1
        }

        return 0
    }

    function looks_like_bullet(s) {
        return (s ~ /^[[:space:]]*[»•*-][[:space:]]+/)
    }

    function clean_bullet_prefix(s) {
        sub(/^[[:space:]]*[»•*-][[:space:]]+/, "- ", s)
        return s
    }

    function flush_paragraph() {
        if (paragraph != "") {
            print paragraph "\n"
            paragraph = ""
        }
    }

    BEGIN {
        paragraph = ""
    }

    {
        line = $0

        gsub(/\r/, "", line)
        gsub(/[[:space:]]+$/, "", line)
        gsub(/^[[:space:]]+/, "", line)
        gsub(/[[:space:]][[:space:]]+/, " ", line)

        if (is_noise_line(line)) {
            flush_paragraph()
            next
        }

        if (trim(line) == "") {
            flush_paragraph()
            next
        }

        if (looks_like_bullet(line)) {
            flush_paragraph()
            line = clean_bullet_prefix(line)
            print line
            next
        }

        if (looks_like_heading(line)) {
            flush_paragraph()

            if (is_all_caps(line) || length(line) <= 35) {
                print "## " line "\n"
            } else {
                print "### " line "\n"
            }
            next
        }

        if (paragraph == "") {
            paragraph = line
        } else {
            paragraph = paragraph " " line
        }
    }

    END {
        flush_paragraph()
    }
    ' "$input_file" > "$output_file"

    sed -E '
        s/[[:space:]]+([,.;:!?])/\1/g;
        :a;N;$!ba;s/\n{3,}/\n\n/g
    ' "$output_file" > "${output_file}.tmp" && mv "${output_file}.tmp" "$output_file"
}


# =========================
# LIGHT CLASSIFICATION
# =========================

classify_output() {
    local method="$1"
    local chars="$2"
    local words="$3"
    local pages="$4"

    if [ "$method" = "ocr" ]; then
        if [ "$words" -lt 40 ]; then
            echo "low_quality"
        else
            echo "ocr_forced"
        fi
        return
    fi

    if [ "$pages" -gt 0 ]; then
        local density=$((chars / pages))
        if [ "$density" -lt 120 ]; then
            echo "mixed"
        else
            echo "native_text"
        fi
    else
        echo "native_text"
    fi
}


# =========================
# PROCESS ONE PDF
# =========================

process_one_pdf() {
    local f="$1"

    local rel out_base tmp_prefix out_raw errfile
    local pages pdf_size start_ts end_ts duration
    local method status class chars words chars_per_page
    local tmp_txt tmp_txt2 tmp_pdf_ocr final_out
    local short_id

    rel="$(safe_relpath "$f")"
    out_base="$(make_output_base "$rel")"

    mkdir -p "$(dirname "$out_base")"
    mkdir -p "$PER_FILE_LOG_DIR" "$TMP_DIR"

    short_id="$(make_short_id "$rel")"
    tmp_prefix="$TMP_DIR/$short_id"

    errfile="${tmp_prefix}.err"
    tmp_txt="${tmp_prefix}.native.txt"
    tmp_txt2="${tmp_prefix}.ocr.txt"
    tmp_pdf_ocr="${tmp_prefix}.ocr.pdf"
    out_raw="${tmp_prefix}.raw.md"

    start_ts=$(date +%s)
    pdf_size=$(stat -c%s "$f" 2>/dev/null || echo 0)
    pages=$(pdfinfo "$f" 2>/dev/null | awk -F: '/^Pages/ {gsub(/ /, "", $2); print $2}')
    pages="${pages:-0}"

    method=""
    status="failed"
    class="failed"
    chars=0
    words=0
    chars_per_page=0

    if ls "${out_base}"__*.md >/dev/null 2>&1; then
        echo "SKIPPED: $f" > "${tmp_prefix}.status"
        return 0
    fi

    : > "$errfile"

    # Native extraction
    if timeout "${TIMEOUT_SECONDS}s" pdftotext "$f" - > "$tmp_txt" 2>> "$errfile"; then
        if is_valid_text "$tmp_txt"; then
            method="native"
            status="success"
            cp "$tmp_txt" "$out_raw"
        fi
    fi

    # OCR fallback
    if [ "$status" != "success" ]; then
        if timeout "${TIMEOUT_SECONDS}s" ocrmypdf \
            --force-ocr \
            --output-type pdf \
            -l "$OCR_LANGS" \
            "$f" "$tmp_pdf_ocr" >> "$errfile" 2>&1; then

            if pdftotext "$tmp_pdf_ocr" - > "$tmp_txt2" 2>> "$errfile"; then
                if is_valid_text "$tmp_txt2"; then
                    method="ocr"
                    status="success"
                    cp "$tmp_txt2" "$out_raw"
                fi
            fi
        fi
    fi

    # Final output
    if [ "$status" = "success" ]; then
        chars=$(count_alnum_chars "$out_raw")
        words=$(count_words "$out_raw")

        if [ "${pages:-0}" -gt 0 ]; then
            chars_per_page=$((chars / pages))
        else
            chars_per_page=0
        fi

        class=$(classify_output "$method" "$chars" "$words" "$pages")
        final_out="${out_base}__${class}.md"

        clean_markdown "$out_raw" "$final_out"
        rm -f "$out_raw"

        end_ts=$(date +%s)
        duration=$((end_ts - start_ts))

        {
            echo "FILE=$f"
            echo "RELATIVE_PATH=$rel"
            echo "OUTPUT=$final_out"
            echo "STATUS=success"
            echo "METHOD=$method"
            echo "CLASS=$class"
            echo "PAGES=$pages"
            echo "PDF_SIZE_BYTES=$pdf_size"
            echo "ALNUM_CHARS=$chars"
            echo "WORDS=$words"
            echo "CHARS_PER_PAGE=$chars_per_page"
            echo "DURATION_SECONDS=$duration"
        } > "${tmp_prefix}.status"

        return 0
    fi

    end_ts=$(date +%s)
    duration=$((end_ts - start_ts))

    {
        echo "FILE=$f"
        echo "RELATIVE_PATH=$rel"
        echo "OUTPUT="
        echo "STATUS=failed"
        echo "METHOD=none"
        echo "CLASS=failed"
        echo "PAGES=$pages"
        echo "PDF_SIZE_BYTES=$pdf_size"
        echo "ALNUM_CHARS=0"
        echo "WORDS=0"
        echo "CHARS_PER_PAGE=0"
        echo "DURATION_SECONDS=$duration"
        echo "ERROR_FILE=$errfile"
    } > "${tmp_prefix}.status"

    return 0
}


# =========================
# REAL-TIME PROGRESS
# =========================

show_progress() {
    local total="$1"
    local done success failed skipped ocr native
    local start now elapsed percent
    local bar_width filled empty bar
    local rate_x10 remain
    local rate_display

    start=$(date +%s)
    bar_width=30

    while true; do
        done=$(find "$TMP_DIR" -type f -name "*.status" 2>/dev/null | wc -l | tr -d ' ')
        success=$(grep -h '^STATUS=success' "$TMP_DIR"/*.status 2>/dev/null | wc -l | tr -d ' ')
        failed=$(grep -h '^STATUS=failed' "$TMP_DIR"/*.status 2>/dev/null | wc -l | tr -d ' ')
        skipped=$(grep -h '^SKIPPED:' "$TMP_DIR"/*.status 2>/dev/null | wc -l | tr -d ' ')
        ocr=$(grep -h '^METHOD=ocr' "$TMP_DIR"/*.status 2>/dev/null | wc -l | tr -d ' ')
        native=$(grep -h '^METHOD=native' "$TMP_DIR"/*.status 2>/dev/null | wc -l | tr -d ' ')

        now=$(date +%s)
        elapsed=$((now - start))

        if [ "$total" -gt 0 ]; then
            percent=$((done * 100 / total))
        else
            percent=0
        fi

        # rate with one decimal precision using integer math
        if [ "$elapsed" -gt 0 ]; then
            rate_x10=$((done * 10 / elapsed))
        else
            rate_x10=0
        fi

        if [ "$rate_x10" -gt 0 ]; then
            remain=$(((total - done) * 10 / rate_x10))
        else
            remain=0
        fi

        filled=$((percent * bar_width / 100))
        empty=$((bar_width - filled))

        bar="$(printf '%*s' "$filled" '' | tr ' ' '#')"
        bar="${bar}$(printf '%*s' "$empty" '' | tr ' ' '-')"

        rate_display="${rate_x10%?}.${rate_x10#${rate_x10%?}}"
        if [ "$rate_x10" -lt 10 ]; then
            rate_display="0.$rate_x10"
        fi

        printf "\r[%s] %3d%% | done=%d/%d | success=%d | failed=%d | skipped=%d | native=%d | ocr=%d | rate=%s pdf/s | elapsed=%ss | eta=%ss" \
            "$bar" "$percent" "$done" "$total" "$success" "$failed" "$skipped" "$native" "$ocr" "$rate_display" "$elapsed" "$remain"

        if [ "$done" -ge "$total" ]; then
            echo
            break
        fi

        sleep 2
    done
}


# =========================
# EXPORTS FOR XARGS WORKERS
# =========================

export INPUT_DIR OUTPUT_DIR LOG_DIR JOBS TIMEOUT_SECONDS MIN_TEXT_CHARS OCR_LANGS
export PER_FILE_LOG_DIR TMP_DIR
export SUCCESS_LOG OCR_LOG FAILED_LOG SKIPPED_LOG ERROR_LOG STATS_GLOBAL_LOG

export -f command_exists
export -f make_short_id
export -f count_alnum_chars
export -f count_words
export -f is_valid_text
export -f safe_relpath
export -f make_output_base
export -f clean_markdown
export -f classify_output
export -f process_one_pdf


# =========================
# AGGREGATE LOGS
# =========================

aggregate_logs() {
    : > "$SUCCESS_LOG"
    : > "$OCR_LOG"
    : > "$FAILED_LOG"
    : > "$SKIPPED_LOG"
    : > "$ERROR_LOG"
    : > "$STATS_GLOBAL_LOG"

    local total success failed skipped native_count ocr_count mixed_count lowq_count
    local native_text_count total_words total_chars total_pages total_duration
    local avg_words avg_chars avg_duration
    local file status method class words chars pages duration err_ref
    local status_files=()

    total=0
    success=0
    failed=0
    skipped=0
    native_count=0
    ocr_count=0
    native_text_count=0
    mixed_count=0
    lowq_count=0
    total_words=0
    total_chars=0
    total_pages=0
    total_duration=0

    mapfile -t status_files < <(find "$TMP_DIR" -type f -name "*.status")

    for status_file in "${status_files[@]}"; do
        total=$((total + 1))

        if grep -q '^SKIPPED:' "$status_file"; then
            file=$(sed 's/^SKIPPED: //' "$status_file")
            skipped=$((skipped + 1))
            echo "$file" >> "$SKIPPED_LOG"
            continue
        fi

        file=$(grep '^FILE=' "$status_file" | cut -d= -f2-)
        status=$(grep '^STATUS=' "$status_file" | cut -d= -f2-)
        method=$(grep '^METHOD=' "$status_file" | cut -d= -f2-)
        class=$(grep '^CLASS=' "$status_file" | cut -d= -f2-)
        words=$(grep '^WORDS=' "$status_file" | cut -d= -f2-)
        chars=$(grep '^ALNUM_CHARS=' "$status_file" | cut -d= -f2-)
        pages=$(grep '^PAGES=' "$status_file" | cut -d= -f2-)
        duration=$(grep '^DURATION_SECONDS=' "$status_file" | cut -d= -f2-)
        err_ref=$(grep '^ERROR_FILE=' "$status_file" | cut -d= -f2-)

        words="${words:-0}"
        chars="${chars:-0}"
        pages="${pages:-0}"
        duration="${duration:-0}"

        total_words=$((total_words + words))
        total_chars=$((total_chars + chars))
        total_pages=$((total_pages + pages))
        total_duration=$((total_duration + duration))

        if [ "$status" = "success" ]; then
            success=$((success + 1))
            echo "$file" >> "$SUCCESS_LOG"

            if [ "$method" = "native" ]; then
                native_count=$((native_count + 1))
            fi

            if [ "$method" = "ocr" ]; then
                ocr_count=$((ocr_count + 1))
                echo "$file" >> "$OCR_LOG"
            fi

            case "$class" in
                native_text) native_text_count=$((native_text_count + 1)) ;;
                mixed) mixed_count=$((mixed_count + 1)) ;;
                low_quality) lowq_count=$((lowq_count + 1)) ;;
            esac
        else
            failed=$((failed + 1))
            echo "$file" >> "$FAILED_LOG"

            if [ -n "${err_ref:-}" ] && [ -f "$err_ref" ]; then
                {
                    echo "------ ERROR ------"
                    echo "FILE: $file"
                    echo "DATE: $(date)"
                    cat "$err_ref"
                    echo
                } >> "$ERROR_LOG"
            fi
        fi
    done

    if [ "$total" -gt 0 ]; then
        avg_words=$((total_words / total))
        avg_chars=$((total_chars / total))
        avg_duration=$((total_duration / total))
    else
        avg_words=0
        avg_chars=0
        avg_duration=0
    fi

    {
        echo "========================================"
        echo "GLOBAL DATASET STATS"
        echo "========================================"
        echo "TOTAL_FILES=$total"
        echo "SUCCESS=$success"
        echo "FAILED=$failed"
        echo "SKIPPED=$skipped"
        echo "METHOD_NATIVE=$native_count"
        echo "METHOD_OCR=$ocr_count"
        echo "CLASS_NATIVE_TEXT=$native_text_count"
        echo "CLASS_MIXED=$mixed_count"
        echo "CLASS_LOW_QUALITY=$lowq_count"
        echo "TOTAL_WORDS=$total_words"
        echo "TOTAL_ALNUM_CHARS=$total_chars"
        echo "TOTAL_PAGES=$total_pages"
        echo "TOTAL_DURATION_SECONDS=$total_duration"
        echo "AVG_WORDS_PER_FILE=$avg_words"
        echo "AVG_ALNUM_CHARS_PER_FILE=$avg_chars"
        echo "AVG_DURATION_SECONDS_PER_FILE=$avg_duration"
        echo "JOBS=$JOBS"
        echo "TIMEOUT_SECONDS=$TIMEOUT_SECONDS"
        echo "OCR_LANGS=$OCR_LANGS"
        echo "========================================"
    } > "$STATS_GLOBAL_LOG"
}


# =========================
# MAIN
# =========================

main() {
    install_dependencies

    mkdir -p "$OUTPUT_DIR" "$LOG_DIR" "$PER_FILE_LOG_DIR" "$TMP_DIR"
    : > "$SUCCESS_LOG"
    : > "$OCR_LOG"
    : > "$FAILED_LOG"
    : > "$SKIPPED_LOG"
    : > "$ERROR_LOG"
    : > "$STATS_GLOBAL_LOG"

    echo "========================================"
    echo "PDF -> Markdown extraction started"
    echo "INPUT_DIR=$INPUT_DIR"
    echo "OUTPUT_DIR=$OUTPUT_DIR"
    echo "LOG_DIR=$LOG_DIR"
    echo "JOBS=$JOBS"
    echo "TIMEOUT_SECONDS=$TIMEOUT_SECONDS"
    echo "OCR_LANGS=$OCR_LANGS"
    echo "INSTALL_DEPS=$INSTALL_DEPS"
    echo "========================================"

    mapfile -d '' PDFS < <(find "$INPUT_DIR" -type f -iname "*.pdf" -print0)

    if [ "${#PDFS[@]}" -eq 0 ]; then
        echo "No PDF files found in $INPUT_DIR"
        exit 0
    fi

    TOTAL_FILES="${#PDFS[@]}"
    echo "Total PDF files found: $TOTAL_FILES"

    show_progress "$TOTAL_FILES" &
    PROGRESS_PID=$!

    printf '%s\0' "${PDFS[@]}" | xargs -0 -n1 -P "$JOBS" bash -c 'process_one_pdf "$1"' _

    wait "$PROGRESS_PID"
    PROGRESS_PID=""

    aggregate_logs

    echo "========================================"
    echo "Finished"
    echo "Success log      : $SUCCESS_LOG"
    echo "OCR log          : $OCR_LOG"
    echo "Failed log       : $FAILED_LOG"
    echo "Skipped log      : $SKIPPED_LOG"
    echo "Errors log       : $ERROR_LOG"
    echo "Global stats log : $STATS_GLOBAL_LOG"
    echo "========================================"
}

main "$@"
