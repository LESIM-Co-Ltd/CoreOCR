// The Swift Programming Language
// https://docs.swift.org/swift-book

// VisionとAppKitはCoreOCRLibがインポートするので、ここでは不要な場合がある
import Vision // Needed for VNRequestTextRecognitionLevel
// import AppKit
import ArgumentParser
import Foundation // URLのため
import CoreOCRLib // Import the shared OCR library

@main
struct CoreOCRCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "coreocr", // Command name
        abstract: "Extracts text from image or PDF files using Vision framework." // Tool description
    )

    @Argument(help: "Path to the image or PDF file to perform OCR on.")
    var filePath: String

    @Option(name: .shortAndLong, help: "Comma-separated list of languages for recognition (e.g., en-US,ja-JP). Defaults to auto-detect. See Vision docs for supported languages.")
    var languages: String?

    @Option(name: .long, help: "Recognition level ('accurate' or 'fast'). Defaults to 'accurate'.")
    var level: String = "accurate"

    @Flag(name: [.long, .short], help: "Process PDF pages in parallel (faster, but page order is not guaranteed).")
    var parallel: Bool = false // Default is false (preserve order)

    // Helper to print the progress bar
    private func printProgressBar(currentPage: Int, totalPages: Int) {
        let barWidth = 40 // Width of the progress bar
        let progress = Double(currentPage) / Double(totalPages)
        let filledWidth = Int(progress * Double(barWidth))
        let emptyWidth = barWidth - filledWidth

        let filledPart = String(repeating: "=", count: filledWidth)
        let emptyPart = String(repeating: "-", count: emptyWidth)
        let percentage = Int(progress * 100)

        // Use \r to return cursor to the beginning of the line to overwrite
        // Output to stderr to avoid mixing with the result text (stdout)
        fputs("\rProcessing PDF: [\(filledPart)>\(emptyPart)] \(currentPage)/\(totalPages) (\(percentage)%)", stderr)
        fflush(stderr) // Flush buffer for immediate display
    }

    func run() throws {
        let ocrService = CoreOCRService()
        var isPDF = false // Flag to check if the input is a PDF

        // Check file extension
        if let url = URL(string: filePath), url.pathExtension.lowercased() == "pdf" {
             isPDF = true
         } else if URL(fileURLWithPath: filePath).pathExtension.lowercased() == "pdf" {
              isPDF = true
          }

        // Define the progress handler (only set for PDF files)
        let progressHandler: ProgressHandler? = isPDF ? { currentPage, totalPages in
             self.printProgressBar(currentPage: currentPage, totalPages: totalPages)
         } : nil

        // Parse language option
        let recognitionLanguages = languages?.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        // Parse recognition level option
        let recognitionLevel: VNRequestTextRecognitionLevel
        switch level.lowercased() {
        case "fast":
            recognitionLevel = .fast
        case "accurate":
            recognitionLevel = .accurate
        default:
            // Print newline before error if progress bar might be visible
            fputs("\n", stderr)
            fputs("Error: Invalid recognition level. Use 'accurate' or 'fast'.\n", stderr)
            throw ExitCode.failure
        }

        // Execute OCR service
        // preservePageOrder is true if --parallel is NOT set
        let result = ocrService.recognizeText(
            from: filePath,
            recognitionLanguages: recognitionLanguages,
            recognitionLevel: recognitionLevel,
            preservePageOrder: !parallel, // Pass the inverse of the parallel flag
            progressHandler: progressHandler
        )

        // Print newline after PDF processing to clear the progress bar
        if isPDF {
            fputs("\n", stderr)
            fflush(stderr)
        }

        // Handle the result
        switch result {
        case .success(let recognizedText):
            // Print recognized text to stdout
            print(recognizedText)
             // Default exit code is success
        case .failure(let error):
            // Print error message to stderr (already has newline from progress bar clearing or default error message)
            fputs("Error: \(error.localizedDescription)\n", stderr)
            throw ExitCode.failure // Exit with failure code
        }
    }
}

// Helper to write to stderr
func fputs(_ string: String, _ stream: UnsafeMutablePointer<FILE>) {
    _ = string.withCString { ptr in
        Darwin.fputs(ptr, stream)
    }
}
