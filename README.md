# IA Intelligent PDF to Markdown Converter

An intelligent and scalable Linux pipeline for converting large PDF datasets into clean, structured Markdown using OCR, multi-core processing, smart text extraction, and Markdown cleaning.

\---

## 🚀 Key Features

* Native PDF text extraction (`pdftotext`)
* OCR fallback (`ocrmypdf` + `tesseract`)
* Multi-core processing (parallel execution)
* Real-time progress tracking
* Markdown cleaning \& formatting
* Automatic file classification
* Cross-Linux support (Ubuntu, Debian, Fedora, RHEL, etc.)

\---

## ⚙️ Pipeline Overview

PDF → Text extraction → OCR fallback → Cleaning → Classification → Markdown output

\---

## 🔐 Safe Dependency Installation (NEW)

This project now uses a **fully interactive and safe dependency system**.

### 🧠 How it works

When required system tools are missing, the script will:

1. Detect missing dependencies
2. Explain what each tool does
3. Show installation commands
4. Ask the user how to proceed

\---

### 🧭 User choices

You will be prompted:

1. Install manually (recommended)
2. Let script install using sudo
3. Cancel execution

\---

### 🔐 Why this is better

* No silent `sudo` execution
* Full transparency of system changes
* User decides installation method
* Safer for servers, WSL, and production systems

\---

### 💡 Recommended mode

* Option 1 → safest (manual install)
* Option 2 → convenience mode (trusted machines)

\---

## 📦 Installation

Clone repository:

```bash
git clone git@github.com:Firas-BENBELGACEM/IA-intelligent-pdf-to-md-converter.git
cd IA-intelligent-pdf-to-md-converter
```

\---

## ▶️ Usage

```bash
chmod +x intelligent\\\_pdf\\\_to\\\_md\\\_converter.sh
./intelligent\\\_pdf\\\_to\\\_md\\\_converter.sh
```

\---

## ⚡ Example

```bash
INPUT\\\_DIR="./pdfs" JOBS=4 ./intelligent\\\_pdf\\\_to\\\_md\\\_converter.sh
```

\---

## 📊 Output

* Clean Markdown files
* Classification tags:

  * native\_text
  * ocr\_forced
  * mixed
  * low\_quality

\---

## 🧠 Use Cases

* AI dataset preparation
* RAG pipelines
* Knowledge base extraction
* LLM training datasets
* Document preprocessing

\---

## 👤 Author

Firas + Claude Code ;) 



