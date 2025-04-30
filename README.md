# CoreOCR

A simple command-line tool and Swift library for performing Optical Character Recognition (OCR) on images and PDF files using the macOS Vision framework.

## Features

*   Recognizes text from various image formats (PNG, JPEG, etc.) and PDF files.
*   Provides both a command-line interface (CLI) and a Swift library (`CoreOCRLib`).
*   Supports specifying recognition languages (e.g., English, Japanese).
*   Supports choosing recognition level (accuracy vs. speed).
*   **Preserves page order for PDF output by default.**
*   **Optionally process PDF pages in parallel for potential speedup (page order not guaranteed).**
*   Displays progress for PDF file processing in the CLI.
*   Built purely with native macOS frameworks (`Vision`, `PDFKit`, `AppKit`).

## Requirements

*   macOS 10.15 or later
*   Xcode command-line tools (or Xcode) including Swift 6 or later

## Installation (using Homebrew)

You can install the `CoreOCRCLI` tool using Homebrew:

```bash
brew tap LESIM-Co-Ltd/coreocr
brew install coreocr
```

This will install the command-line tool as `coreocr`.

## CLI Usage

The command-line tool `coreocr` takes a file path as input and prints the recognized text to standard output. By default, text from PDF pages is output in the original page order. Progress for PDF files and any errors are printed to standard error.

**Basic Usage (Page order preserved):**

```bash
# For an image file
coreocr /path/to/your/image.png

# For a PDF file (progress will be shown on stderr)
coreocr /path/to/your/document.pdf
```

**Options:**

*   `-l, --languages <langs>`: Specify comma-separated languages for recognition (e.g., `en-US,ja-JP`). Defaults to automatic detection.
    ```bash
    coreocr -l en-US,es-ES /path/to/file.pdf
    ```
*   `--level <level>`: Set the recognition level (`accurate` or `fast`). Defaults to `accurate`.
    ```bash
    coreocr --level fast /path/to/image.jpg
    ```
*   `-p, --parallel`: Process PDF pages in parallel. This might be faster but does **not** guarantee the original page order in the output.
    ```bash
    coreocr --parallel /path/to/your/document.pdf
    # Or using the short option:
    coreocr -p /path/to/your/document.pdf
    ```

## Library Usage (`CoreOCRLib`)

You can use the `CoreOCRLib` module in your own Swift projects.

1.  **Add Dependency:** Add `CoreOCR` as a dependency in your `Package.swift` file:

    ```swift
    // swift-tools-version:5.9 // Or newer
    import PackageDescription

    let package = Package(
        name: "YourProject",
        platforms: [
            .macOS(.v10_15) // Match CoreOCR requirement
        ],
        dependencies: [
            // Add CoreOCR dependency (use correct path or Git URL)
            .package(url: "https://github.com/your-username/CoreOCR.git", from: "1.0.0") // Or .package(path: "../CoreOCR")
        ],
        targets: [
            .executableTarget(
                name: "YourProject",
                dependencies: [
                    .product(name: "CoreOCRLib", package: "CoreOCR") // Depend on the library product
                ]
            ),
        ]
    )
    ```

2.  **Use in Code:** Import `CoreOCRLib` and use `CoreOCRService`:

    ```swift
    import CoreOCRLib
    import Foundation // For ExitCode

    // Example usage
    let ocrService = CoreOCRService()
    let filePath = "/path/to/your/file.pdf" // Or an image path

    // Optional progress handler for PDFs
    let progressHandler: ProgressHandler = { currentPage, totalPages in
        print("Processing page \(currentPage) of \(totalPages)...")
    }

    // Example: Preserve page order (default)
    let orderedResult = ocrService.recognizeText(
        from: filePath,
        progressHandler: progressHandler
    )

    // Example: Use parallel processing (order not guaranteed)
    let parallelResult = ocrService.recognizeText(
        from: filePath,
        preservePageOrder: false, // Set to false for parallel processing
        progressHandler: progressHandler
    )

    // Handle the result (e.g., for orderedResult)
    switch orderedResult {
    case .success(let text):
        print("Recognized Text (Ordered):")
        print(text)
    case .failure(let error):
        print("OCR Error: \(error.localizedDescription)")
    }
    ```

## Building (Manual)

If you prefer to build from source:

1.  Clone the repository:
    ```bash
    git clone https://github.com/LESIM-Co-Ltd/CoreOCR.git # Replace with your repo URL
    cd CoreOCR
    ```
2.  Build the project (this will build both the library and the CLI tool):
    ```bash
    swift build -c release
    ```
    The executable will be located at `.build/release/CoreOCRCLI`. 

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details (you should add a LICENSE file containing the MIT license text).