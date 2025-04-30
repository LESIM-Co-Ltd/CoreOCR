import Vision
import AppKit // Required for NSImage, used for image loading
@preconcurrency import PDFKit // Required for PDFDocument, suppress Sendable warnings for now
import Foundation

/// Errors that can occur during OCR processing.
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
            return "Failed to convert image format for Vision processing."
        case .visionRequestFailed(let underlyingError):
            return "Vision text recognition request failed: \(underlyingError.localizedDescription)"
        case .unexpectedResultType:
            return "Vision request returned an unexpected result type."
        case .pdfPageImageConversionFailed(let page):
            return "Failed to convert PDF page to image (Page: \(page + 1))."
        }
    }
}

/// Callback type for reporting progress, typically used for PDF processing.
/// Parameters are: (current page number, total number of pages).
public typealias ProgressHandler = (_ currentPage: Int, _ totalPages: Int) -> Void

/// Service class providing OCR functionality using Apple's Vision framework.
public struct CoreOCRService {

    public init() {}

    /// Recognizes text from the specified image or PDF file path.
    ///
    /// - Parameter filePath: Path to the image or PDF file.
    /// - Parameter recognitionLanguages: An array of language codes (e.g., `["en-US", "ja-JP"]`) to prioritize.
    ///                                   If `nil` or empty, Vision attempts automatic language detection.
    /// - Parameter recognitionLevel: The recognition level, `.accurate` or `.fast`. Defaults to `.accurate`.
    ///                               Note: `.fast` might be less stable for some PDFs.
    /// - Parameter preservePageOrder: If `true` (default), processes PDF pages sequentially to ensure the output text order matches the page order.
    ///                                If `false`, pages may be processed in parallel for potential speedup, but text order is not guaranteed.
    /// - Parameter progressHandler: An optional closure to receive progress updates during PDF processing.
    /// - Returns: A `Result` containing the recognized text as a single `String` on success, or an `OCRError` on failure.
    public func recognizeText(from filePath: String, recognitionLanguages: [String]? = nil, recognitionLevel: VNRequestTextRecognitionLevel = .accurate, preservePageOrder: Bool = true, progressHandler: ProgressHandler? = nil) -> Result<String, OCRError> {
        let fileURL = URL(fileURLWithPath: filePath)

        guard FileManager.default.fileExists(atPath: filePath) else {
            return .failure(.fileNotFound(path: filePath))
        }

        // Determine file type and delegate to appropriate method.
        if fileURL.pathExtension.lowercased() == "pdf" {
            return recognizeTextFromPDF(pdfURL: fileURL, recognitionLanguages: recognitionLanguages, recognitionLevel: recognitionLevel, preservePageOrder: preservePageOrder, progressHandler: progressHandler)
        } else {
            guard let nsImage = NSImage(contentsOf: fileURL) else {
                return .failure(.imageLoadFailed(path: filePath))
            }
            // Report progress for single image (1 out of 1 page).
            progressHandler?(1, 1)
            return recognizeTextFromImage(nsImage: nsImage, recognitionLanguages: recognitionLanguages, recognitionLevel: recognitionLevel)
        }
    }

    /// Recognizes text from an `NSImage` instance.
    private func recognizeTextFromImage(nsImage: NSImage, recognitionLanguages: [String]?, recognitionLevel: VNRequestTextRecognitionLevel) -> Result<String, OCRError> {
        // Attempt to get a CGImage representation suitable for Vision.
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .failure(.imageConversionFailed)
        }
        return Self.performVisionRequest(cgImage: cgImage, recognitionLanguages: recognitionLanguages, recognitionLevel: recognitionLevel)
    }

    /// Recognizes text from a PDF file, handling page processing sequentially or in parallel.
    private func recognizeTextFromPDF(pdfURL: URL, recognitionLanguages: [String]?, recognitionLevel: VNRequestTextRecognitionLevel, preservePageOrder: Bool, progressHandler: ProgressHandler?) -> Result<String, OCRError> {
        guard let pdfDocument = PDFDocument(url: pdfURL) else {
            return .failure(.pdfLoadFailed(path: pdfURL.path))
        }
        let totalPages = pdfDocument.pageCount
        guard totalPages > 0 else {
            return .success("") // Return empty string for an empty PDF.
        }

        if preservePageOrder {
            // --- Sequential Processing --- 
            var pageTexts: [String] = []
            var pageErrors: [Error] = [] // Collect errors encountered during page processing.

            for i in 0..<totalPages {
                guard let page = pdfDocument.page(at: i) else {
                    // This should ideally not happen if pageCount is correct.
                    print("Warning: Could not retrieve PDF page \(i + 1).")
                    let error = OCRError.pdfPageImageConversionFailed(page: i)
                    pageErrors.append(error)
                    progressHandler?(i + 1, totalPages)
                    continue
                }

                // Convert PDF page to an image (CGImage) for Vision processing.
                // Using a scale factor based on 300 DPI for potentially better quality.
                let pageSize = page.bounds(for: .cropBox)
                let scaleFactor: CGFloat = 300.0 / 72.0 
                let imageSize = NSSize(width: pageSize.width * scaleFactor, height: pageSize.height * scaleFactor)
                let thumbnail = page.thumbnail(of: imageSize, for: .cropBox)

                guard let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    print("Warning: Could not convert PDF page \(i + 1) to image.")
                    let error = OCRError.pdfPageImageConversionFailed(page: i)
                    pageErrors.append(error)
                    progressHandler?(i + 1, totalPages)
                    continue
                }

                // Perform OCR on the single page image.
                let result = Self.performVisionRequest(cgImage: cgImage, recognitionLanguages: recognitionLanguages, recognitionLevel: recognitionLevel)

                switch result {
                case .success(let text):
                    pageTexts.append(text)
                case .failure(let error):
                    // Log the error but continue processing other pages.
                    print("Warning: OCR failed for PDF page \(i + 1): \(error.localizedDescription)")
                    pageErrors.append(error)
                    pageTexts.append("") // Append empty string to maintain page order correspondence.
                }
                progressHandler?(i + 1, totalPages)
            }

            // Combine results and check for errors.
            let combinedText = pageTexts.joined(separator: "\n\n")
            if let firstError = pageErrors.first {
                // If any page failed, return the first error encountered.
                if let ocrError = firstError as? OCRError {
                    return .failure(ocrError)
                } else {
                    return .failure(.visionRequestFailed(firstError))
                }
            } else {
                 // No errors encountered during page processing.
                return .success(combinedText)
            }

        } else {
            // --- Parallel Processing --- 
            var recognizedTexts = Array(repeating: "", count: totalPages) // Store results in order.
            var pageErrors = Array<Error?>(repeating: nil, count: totalPages) // Store potential errors per page.
            var processedPages = 0
            let lock = NSLock() // To safely update shared variables.
            let dispatchGroup = DispatchGroup()

            for i in 0..<totalPages {
                dispatchGroup.enter()
                // Use a background queue for parallel execution.
                DispatchQueue.global().async {
                    defer { dispatchGroup.leave() } // Ensure leave is always called.

                    guard let page = pdfDocument.page(at: i) else {
                        print("Warning: Could not retrieve PDF page \(i + 1) in async task.")
                        let error = OCRError.pdfPageImageConversionFailed(page: i)
                        lock.lock()
                        pageErrors[i] = error
                        processedPages += 1
                        progressHandler?(processedPages, totalPages)
                        lock.unlock()
                        return
                    }

                    let pageSize = page.bounds(for: .cropBox)
                    let scaleFactor: CGFloat = 300.0 / 72.0
                    let imageSize = NSSize(width: pageSize.width * scaleFactor, height: pageSize.height * scaleFactor)
                    let thumbnail = page.thumbnail(of: imageSize, for: .cropBox)

                    guard let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                        print("Warning: Could not convert PDF page \(i + 1) to image in async task.")
                        let error = OCRError.pdfPageImageConversionFailed(page: i)
                        lock.lock()
                        pageErrors[i] = error
                        processedPages += 1
                        progressHandler?(processedPages, totalPages)
                        lock.unlock()
                        return
                    }

                    let result = Self.performVisionRequest(cgImage: cgImage, recognitionLanguages: recognitionLanguages, recognitionLevel: recognitionLevel)

                    lock.lock()
                    switch result {
                    case .success(let text):
                        if !text.isEmpty {
                             recognizedTexts[i] = text // Store text at the correct index.
                        }
                    case .failure(let error):
                        print("Warning: OCR failed for PDF page \(i + 1): \(error.localizedDescription)")
                         pageErrors[i] = error // Store error at the correct index.
                    }
                    processedPages += 1
                    progressHandler?(processedPages, totalPages)
                    lock.unlock()
                }
            }

            dispatchGroup.wait() // Wait for all async tasks to complete.

            // Check for errors after all pages are processed.
            let firstError = pageErrors.compactMap { $0 }.first
            if let error = firstError {
                 if let ocrError = error as? OCRError {
                     return .failure(ocrError)
                 } else {
                     return .failure(.visionRequestFailed(error))
                 }
             } else {
                 // No errors, combine the texts in order.
                 let combinedText = recognizedTexts.joined(separator: "\n\n")
                 return .success(combinedText)
             }
        }
    }

    /// Performs the actual Vision text recognition request on a given `CGImage`.
    /// This method is static as it doesn't depend on the service instance state.
    static private func performVisionRequest(cgImage: CGImage, recognitionLanguages: [String]?, recognitionLevel: VNRequestTextRecognitionLevel) -> Result<String, OCRError> {
        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        var recognizedText = ""
        var recognitionError: OCRError? = nil
        // Use a semaphore to wait for the asynchronous Vision request completion handler.
        let semaphore = DispatchSemaphore(value: 0)

        let request = VNRecognizeTextRequest { (request, error) in
            defer { semaphore.signal() } // Signal completion.

            if let error = error {
                // If the request itself failed.
                recognitionError = .visionRequestFailed(error)
                return
            }
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                // If results are not the expected type.
                recognitionError = .unexpectedResultType
                return
            }

            // Extract text from observations.
            let pageTextComponents = observations.compactMap { observation -> String? in
                // Get the most confident recognition result.
                observation.topCandidates(1).first?.string
            }
            recognizedText = pageTextComponents.joined(separator: "\n")
            // Note: No text found (empty observations or candidates) is not treated as an error here.
        }

        // Configure the Vision request.
        if let languages = recognitionLanguages, !languages.isEmpty {
             request.recognitionLanguages = languages
        }
        request.recognitionLevel = recognitionLevel
        // request.usesLanguageCorrection = false // Example: Optionally disable language correction.

        do {
            try requestHandler.perform([request])
             // Wait for the completion handler to signal (with a timeout).
             _ = semaphore.wait(timeout: .now() + 60)

             if let error = recognitionError {
                  return .failure(error)
              } else {
                  return .success(recognizedText)
              }
        } catch {
            // Handle errors thrown by requestHandler.perform itself.
            return .failure(.visionRequestFailed(error))
        }
    }
}

// MARK: - C Interface for Python ctypes

/// Error codes for the C interface.
@objc public enum CErrorCode: Int32 {
    case success = 0
    case errorFileNotFound = 1
    case errorImageLoadFailed = 2
    case errorPdfLoadFailed = 3
    case errorVisionRequestFailed = 4
    case errorInvalidParameter = 5
    case errorMemoryAllocation = 6 // Specific error for memory issues
    case errorOther = 7
}

/// Recognition level options for the C interface.
@objc public enum CRecognitionLevel: Int32 {
    case accurate = 0
    case fast = 1
}

/// Frees the memory allocated for a C string returned by the Swift library.
/// This function MUST be called from the calling C code (e.g., Python ctypes)
/// to prevent memory leaks when receiving strings from `recognize_text_c`.
/// - Parameter ptr: A pointer to the C string (char*) previously returned
///                  via `outputResult` or `outputError`.
@_cdecl("free_swift_string")
public func free_swift_string(ptr: UnsafeMutablePointer<CChar>?) {
    // Assumes the string was allocated using strdup, which uses malloc.
    free(ptr)
}

/// C-compatible function to recognize text from a file.
///
/// This function serves as the bridge between Swift and C-based languages like Python (via ctypes).
/// It handles the conversion of C types to Swift types, calls the Swift OCR service,
/// converts the results (or errors) back to C types, and manages memory allocation
/// for the returned strings.
///
/// - Parameter filePath: A C string (UTF-8 encoded) representing the path to the image or PDF file.
/// - Parameter languages: A pointer to an array of C strings (char**), each representing a language code (e.g., "en-US").
///                      Pass `nil` or an empty array (with `languageCount = 0`) for automatic language detection.
/// - Parameter languageCount: The number of elements in the `languages` array.
/// - Parameter level: The desired recognition level (0 for `.accurate`, 1 for `.fast`).
/// - Parameter preserveOrder: Flag to preserve page order in PDFs (0 for `false`, non-zero for `true`).
/// - Parameter outputResult: A pointer to a C string pointer (`char**`). On success, this will be set to point
///                         to a newly allocated C string containing the recognized text. The caller
///                         is responsible for freeing this string using `free_swift_string`.
/// - Parameter outputError: A pointer to a C string pointer (`char**`). On failure, this will be set to point
///                        to a newly allocated C string containing the error description. The caller
///                        is responsible for freeing this string using `free_swift_string`.
/// - Returns: A `CErrorCode` indicating success (0) or the type of error that occurred.
@_cdecl("recognize_text_c")
public func recognize_text_c(
    filePath: UnsafePointer<CChar>,
    languages: UnsafePointer<UnsafePointer<CChar>?>?,
    languageCount: Int32,
    level: Int32,
    preserveOrder: Int32,
    outputResult: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, 
    outputError: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> CErrorCode {

    // Initialize output pointers to nil.
    outputResult.pointee = nil
    outputError.pointee = nil

    // --- Convert C parameters to Swift types ---
    let path = String(cString: filePath)

    var swiftLanguages: [String]? = nil
    if let langPtr = languages, languageCount > 0 {
        swiftLanguages = []
        for i in 0..<Int(languageCount) {
            guard let langCStringPtr = langPtr[i] else {
                let errorMsg = "Invalid language array: contains NULL pointer."
                outputError.pointee = strdup(errorMsg)
                // Check allocation success before returning
                return outputError.pointee == nil ? .errorMemoryAllocation : .errorInvalidParameter
            }
            swiftLanguages?.append(String(cString: langCStringPtr))
        }
    } else if languages != nil && languageCount <= 0 {
        let errorMsg = "Invalid language parameter: non-nil array with count <= 0."
        outputError.pointee = strdup(errorMsg)
        return outputError.pointee == nil ? .errorMemoryAllocation : .errorInvalidParameter
    }

    guard let cRecoLevel = CRecognitionLevel(rawValue: level), 
          let swiftRecognitionLevel = VNRequestTextRecognitionLevel(cRecognitionLevel: cRecoLevel) else {
        let errorMsg = "Invalid recognition level value: \(level)"
        outputError.pointee = strdup(errorMsg)
        return outputError.pointee == nil ? .errorMemoryAllocation : .errorInvalidParameter
    }

    let swiftPreserveOrder = (preserveOrder != 0)

    // --- Call Swift OCR Service ---
    let service = CoreOCRService()
    let result = service.recognizeText(
        from: path,
        recognitionLanguages: swiftLanguages,
        recognitionLevel: swiftRecognitionLevel,
        preservePageOrder: swiftPreserveOrder
        // progressHandler is not exposed via C interface currently.
    )

    // --- Convert Swift Result/Error back to C types ---
    switch result {
    case .success(let recognizedText):
        guard let cStringResult = strdup(recognizedText) else {
            // Handle memory allocation failure for the result string.
            let errorMsg = "Memory allocation failed for result string."
            outputError.pointee = strdup(errorMsg) // Try to report allocation error
             return .errorMemoryAllocation
        }
        outputResult.pointee = cStringResult
        return .success

    case .failure(let error):
        let errorMessage = error.localizedDescription
        guard let cStringError = strdup(errorMessage) else {
            // Memory allocation failed even for the error message.
            return .errorMemoryAllocation
        }
        outputError.pointee = cStringError

        // Map Swift OCRError to CErrorCode for more specific error reporting.
        if let ocrError = error as? OCRError {
            switch ocrError {
            case .fileNotFound: return .errorFileNotFound
            case .imageLoadFailed: return .errorImageLoadFailed
            case .pdfLoadFailed: return .errorPdfLoadFailed
            case .visionRequestFailed: return .errorVisionRequestFailed
            case .imageConversionFailed, .unexpectedResultType, .pdfPageImageConversionFailed:
                 return .errorOther // Map less specific errors to .errorOther
            }
        } else {
            // Non-OCRError types are mapped to .errorOther
            return .errorOther
        }
    }
}

// MARK: - Helpers

/// Extension to initialize VNRequestTextRecognitionLevel from the C enum.
extension VNRequestTextRecognitionLevel {
    init?(cRecognitionLevel: CRecognitionLevel?) {
        guard let level = cRecognitionLevel else { return nil }
        switch level {
        case .accurate: self = .accurate
        case .fast: self = .fast
        }
    }
} 