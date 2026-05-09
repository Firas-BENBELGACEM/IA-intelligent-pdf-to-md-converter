# IA Intelligent PDF to Markdown Converter

An intelligent and scalable Linux pipeline for converting large PDF datasets into clean, structured Markdown using OCR, multi-core processing, smart text extraction, and Markdown cleaning.

---

## Features

- Native PDF text extraction using `pdftotext`
- Forced OCR fallback using `ocrmypdf` + `tesseract`
- Multi-core parallel processing
- Real-time progress monitoring
- Intelligent Markdown cleaning
- Dataset quality statistics
- Automatic lightweight PDF classification
- Cross-distribution Linux support:
  - Ubuntu / Debian
  - CentOS / RHEL
  - Rocky Linux / AlmaLinux
  - Fedora

---

## Pipeline Overview

```text
PDF
 ├── Native text extraction (pdftotext)
 ├── OCR fallback if extraction fails
 ├── Markdown cleaning
 ├── Quality analysis
 ├── File classification
 └── Clean Markdown output
```

---

## Features in Detail

### Native Text Extraction

The script first attempts to extract text directly from the PDF using:

```bash
pdftotext
```

This is much faster and preserves high-quality text when the PDF already contains a valid text layer.

---

### OCR Fallback

If the native extraction fails or produces low-quality output, the script automatically performs forced OCR using:

```bash
ocrmypdf
tesseract
```

Supported OCR languages are configurable.

Default:

```bash
fra+eng
```

---

### Multi-Core Processing

Large datasets are processed in parallel using configurable workers.

Example:

```bash
JOBS=4
```

This significantly improves throughput on multi-core systems.

---

### Intelligent Markdown Cleaning

The pipeline performs automatic cleaning and formatting:

- heading detection
- bullet normalization
- paragraph reconstruction
- whitespace cleanup
- noise filtering

The generated Markdown is much more usable for:
- LLM datasets
- RAG pipelines
- semantic search
- technical documentation
- AI preprocessing

---

### Dataset Quality Statistics

The script automatically generates global statistics:

- total processed files
- OCR usage ratio
- failed files
- extracted words/chars
- average extraction quality
- processing duration

Generated in:

```bash
logs/stats_global.log
```

---

### Output Classification

Generated Markdown files are automatically classified:

```text
__native_text.md
__ocr_forced.md
__mixed.md
__low_quality.md
```

This helps identify problematic PDFs quickly.

---

## Installation

### Clone repository

```bash
git clone https://github.com/YOUR_USERNAME/IA-intelligent-pdf-to-md-converter.git
cd IA-intelligent-pdf-to-md-converter
```

---

## Usage

Make the script executable:

```bash
chmod +x intelligent_pdf_to_md_converter.sh
```

Run:

```bash
./intelligent_pdf_to_md_converter.sh
```

---

## Examples

### Basic usage

```bash
./intelligent_pdf_to_md_converter.sh
```

### Custom input directory

```bash
INPUT_DIR="./pdfs" ./intelligent_pdf_to_md_converter.sh
```

### Multi-core processing

```bash
JOBS=4 ./intelligent_pdf_to_md_converter.sh
```

### Full example

```bash
INPUT_DIR="./pdfs" \
OUTPUT_DIR="./output_md" \
LOG_DIR="./logs" \
JOBS=4 \
OCR_LANGS="fra+eng" \
./intelligent_pdf_to_md_converter.sh
```

---

## Environment Variables

| Variable | Description | Default |
|---|---|---|
| INPUT_DIR | Input PDF directory | . |
| OUTPUT_DIR | Output Markdown directory | output_md |
| LOG_DIR | Logs directory | logs |
| JOBS | Parallel workers | 4 |
| TIMEOUT_SECONDS | Timeout per PDF | 180 |
| OCR_LANGS | OCR languages | fra+eng |
| MIN_TEXT_CHARS | Minimum extracted chars | 40 |
| INSTALL_DEPS | Dependency install mode | auto |

---

## Generated Directories

### Markdown output

```bash
output_md/
```

### Logs

```bash
logs/
```

### Temporary processing files

```bash
logs/tmp/
```

---

## Example Output

```text
output_md/
└── networking/
    ├── eigrp__native_text.md
    ├── ospf__ocr_forced.md
    └── bgp__mixed.md
```

---

## Dependencies

Main dependencies:

- pdftotext
- pdfinfo
- ocrmypdf
- tesseract
- awk
- sed
- xargs

The script can automatically install dependencies on supported Linux distributions.

---

## Supported Systems

Tested on:

- Ubuntu
- Debian
- Fedora
- Rocky Linux
- AlmaLinux
- CentOS Stream

---

## Important Notes

- Do not commit large PDF datasets to GitHub.
- Do not commit generated output directories.
- The repository is intended for the pipeline itself, not datasets.

---

## Potential Use Cases

- AI dataset preparation
- RAG pipelines
- Technical documentation extraction
- PDF corpus preprocessing
- LLM fine-tuning datasets
- Knowledge base generation
- Semantic indexing pipelines

---

## License

MIT License

---

## Author

Firas + Claude code :D 
