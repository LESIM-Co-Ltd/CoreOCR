import Vision
import AppKit // For NSImage, PDFKit
@preconcurrency import PDFKit // For PDF processing (suppress Sendable warnings)
import Foundation

public enum OCRError: Error, LocalizedError {
    case fileNotFound(path: String)
    case imageLoadFailed(path: String)
    case pdfLoadFailed(path: String)
    case imageConversionFailed
    case visionRequestFailed(Error)
    case unexpectedResultType
    case pdfPageImageConversionFailed(page: Int)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .imageLoadFailed(let path):
            return "Failed to load image file: \(path)"
        case .pdfLoadFailed(let path):
            return "Failed to load PDF file: \(path)"
        case .imageConversionFailed:
            return "Failed to convert image format."
        case .visionRequestFailed(let underlyingError):
            return "Vision request failed: \(underlyingError.localizedDescription)"
        case .unexpectedResultType:
            return "Received unexpected result type."
        case .pdfPageImageConversionFailed(let page):
             return "Failed to convert PDF page to image (Page: \(page + 1))."
        }
    }
}

// Type alias for the progress handler callback
public typealias ProgressHandler = (_ currentPage: Int, _ totalPages: Int) -> Void

// Consider Sendable conformance (not done this time, but may be needed in the future)
public struct CoreOCRService {

    // Public initializer
    public init() {}

    /// Recognizes text from the specified file path (image or PDF).
    /// - Parameter filePath: Path to the image or PDF file.
    /// - Parameter recognitionLanguages: List of languages to recognize (e.g., ["en-US", "ja-JP"]). nil for auto-detection.
    /// - Parameter recognitionLevel: Recognition level (`.accurate` or `.fast`).
    /// - Parameter preservePageOrder: If true (default), processes PDF pages sequentially to preserve order. If false, uses parallel processing (faster, order not guaranteed).
    /// - Parameter progressHandler: Optional callback to report progress during PDF processing.
    /// - Returns: A Result containing the recognized text (String) on success, or an OCRError on failure.
    public func recognizeText(from filePath: String, recognitionLanguages: [String]? = nil, recognitionLevel: VNRequestTextRecognitionLevel = .accurate, preservePageOrder: Bool = true, progressHandler: ProgressHandler? = nil) -> Result<String, OCRError> {
        let fileURL = URL(fileURLWithPath: filePath)

        guard FileManager.default.fileExists(atPath: filePath) else {
            return .failure(.fileNotFound(path: filePath))
        }

        // Determine if it's an image or PDF based on the file extension
        if fileURL.pathExtension.lowercased() == "pdf" {
            // Pass the progressHandler
            return recognizeTextFromPDF(pdfURL: fileURL, recognitionLanguages: recognitionLanguages, recognitionLevel: recognitionLevel, preservePageOrder: preservePageOrder, progressHandler: progressHandler)
        } else {
            // Try processing as an image
            guard let nsImage = NSImage(contentsOf: fileURL) else {
                 // If not PDF, treat as image load failure
                return .failure(.imageLoadFailed(path: filePath))
            }
            // Progress for single image (optional call)
            progressHandler?(1, 1)
            return recognizeTextFromImage(nsImage: nsImage, recognitionLanguages: recognitionLanguages, recognitionLevel: recognitionLevel)
        }
    }

    /// Recognizes text from an NSImage.
    private func recognizeTextFromImage(nsImage: NSImage, recognitionLanguages: [String]?, recognitionLevel: VNRequestTextRecognitionLevel) -> Result<String, OCRError> {
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .failure(.imageConversionFailed)
        }
        // Call static method
        return Self.performVisionRequest(cgImage: cgImage, recognitionLanguages: recognitionLanguages, recognitionLevel: recognitionLevel)
    }

    /// Recognizes text from a PDF file URL, optionally preserving page order.
    private func recognizeTextFromPDF(pdfURL: URL, recognitionLanguages: [String]?, recognitionLevel: VNRequestTextRecognitionLevel, preservePageOrder: Bool, progressHandler: ProgressHandler?) -> Result<String, OCRError> {
        guard let pdfDocument = PDFDocument(url: pdfURL) else {
            return .failure(.pdfLoadFailed(path: pdfURL.path))
        }
        let totalPages = pdfDocument.pageCount

        if preservePageOrder {
            // --- Sequential Processing (Preserves Order) ---
            var pageTexts: [String] = [] // Store text for each page
            var pageErrors: [Error] = []

            for i in 0..<totalPages {
                guard let page = pdfDocument.page(at: i) else {
                    print("Warning: Could not get PDF page \(i + 1).")
                    pageErrors.append(OCRError.pdfPageImageConversionFailed(page: i)) // Track error
                    progressHandler?(i + 1, totalPages) // Report progress
                    continue
                }

                let pageSize = page.bounds(for: .cropBox)
                let scaleFactor: CGFloat = 300.0 / 72.0
                let imageSize = NSSize(width: pageSize.width * scaleFactor, height: pageSize.height * scaleFactor)
                let thumbnail = page.thumbnail(of: imageSize, for: .cropBox)

                guard let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    print("Warning: Could not convert PDF page \(i + 1) to image.")
                    pageErrors.append(OCRError.pdfPageImageConversionFailed(page: i))
                    progressHandler?(i + 1, totalPages)
                    continue
                }

                // Perform OCR synchronously for the current page
                let result = Self.performVisionRequest(cgImage: cgImage, recognitionLanguages: recognitionLanguages, recognitionLevel: recognitionLevel)

                switch result {
                case .success(let text):
                    pageTexts.append(text)
                case .failure(let error):
                    print("Warning: OCR failed for PDF page \(i + 1): \(error.localizedDescription)")
                    pageErrors.append(error)
                    pageTexts.append("") // Add empty string on error to maintain page count
                }
                progressHandler?(i + 1, totalPages) // Report progress after processing
            }

            let combinedText = pageTexts.joined(separator: "\n\n")

            if combinedText.isEmpty && !pageErrors.isEmpty {
                if let firstError = pageErrors.first as? OCRError { return .failure(firstError) }
                else if let firstError = pageErrors.first { return .failure(.visionRequestFailed(firstError)) }
            }
            return .success(combinedText)

        } else {
            // --- Parallel Processing (Order Not Guaranteed) ---
            var recognizedText = ""
            var pageErrors: [Error] = []
            var processedPages = 0
            let lock = NSLock()
            let dispatchGroup = DispatchGroup()

            for i in 0..<totalPages {
                dispatchGroup.enter()
                guard let page = pdfDocument.page(at: i) else {
                    print("Warning: Could not get PDF page \(i + 1).")
                    let error = OCRError.pdfPageImageConversionFailed(page: i)
                    lock.lock()
                    pageErrors.append(error)
                    processedPages += 1
                    progressHandler?(processedPages, totalPages)
                    lock.unlock()
                    dispatchGroup.leave()
                    continue
                }

                DispatchQueue.global().async {
                    let pageSize = page.bounds(for: .cropBox)
                    let scaleFactor: CGFloat = 300.0 / 72.0
                    let imageSize = NSSize(width: pageSize.width * scaleFactor, height: pageSize.height * scaleFactor)
                    let thumbnail = page.thumbnail(of: imageSize, for: .cropBox)

                    guard let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                        print("Warning: Could not convert PDF page \(i + 1) to image.")
                        let error = OCRError.pdfPageImageConversionFailed(page: i)
                        lock.lock()
                        pageErrors.append(error)
                        processedPages += 1
                        progressHandler?(processedPages, totalPages)
                        lock.unlock()
                        dispatchGroup.leave()
                        return
                    }

                    let result = Self.performVisionRequest(cgImage: cgImage, recognitionLanguages: recognitionLanguages, recognitionLevel: recognitionLevel)

                    lock.lock()
                    switch result {
                    case .success(let text):
                        if !text.isEmpty {
                            recognizedText += text + "\n\n"
                        }
                    case .failure(let error):
                        print("Warning: OCR failed for PDF page \(i + 1): \(error.localizedDescription)")
                        pageErrors.append(error)
                    }
                    processedPages += 1
                    progressHandler?(processedPages, totalPages)
                    lock.unlock()

                    dispatchGroup.leave()
                }
            }

            dispatchGroup.wait()

            if recognizedText.hasSuffix("\n\n") {
                recognizedText.removeLast(2)
            }

            if recognizedText.isEmpty && !pageErrors.isEmpty {
                 if let firstError = pageErrors.first as? OCRError { return .failure(firstError) }
                 else if let firstError = pageErrors.first { return .failure(.visionRequestFailed(firstError)) }
            }
            return .success(recognizedText)
        }
    }

    // Changed to static method
    static private func performVisionRequest(cgImage: CGImage, recognitionLanguages: [String]?, recognitionLevel: VNRequestTextRecognitionLevel) -> Result<String, OCRError> {
        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        var recognizedText = ""
        var recognitionError: OCRError? = nil
        let semaphore = DispatchSemaphore(value: 0) // For synchronization

        let request = VNRecognizeTextRequest { (request, error) in
            defer { semaphore.signal() } // Signal semaphore upon completion

            if let error = error {
                recognitionError = .visionRequestFailed(error)
                return
            }

            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                recognitionError = .unexpectedResultType
                return
            }

            if !observations.isEmpty {
                let pageText = observations.compactMap { observation in
                    // Get the top candidate (most confident result)
                    observation.topCandidates(1).first?.string
                }.joined(separator: "\n")
                recognizedText = pageText
            }
            // Empty observations is not an error (just no text found)
        }

        // Set options
        if let languages = recognitionLanguages {
             request.recognitionLanguages = languages
        }
        request.recognitionLevel = recognitionLevel // .accurate or .fast

        do {
            // Perform the request
            try requestHandler.perform([request])
             // Although perform can be synchronous, wait for the completion handler via semaphore
             _ = semaphore.wait(timeout: .now() + 60) // Set a timeout (e.g., 60 seconds)

             if let error = recognitionError {
                  return .failure(error)
              } else {
                  return .success(recognizedText) // Return recognized text
              }
        } catch {
             // Handle errors during request performing
            return .failure(.visionRequestFailed(error))
        }
    }
} 