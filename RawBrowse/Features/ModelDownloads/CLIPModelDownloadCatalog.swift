import CryptoKit
import Foundation

/// Stable identifiers for optional model bundles that RawBrowse can manage.
nonisolated enum CLIPModelDownloadID: String, CaseIterable, Codable, Identifiable, Sendable {
    case clipDataComp = "clip-datacomp"
    case sam3

    var id: String {
        rawValue
    }
}

nonisolated struct RawBrowseAIModelLicenceDescriptor: Equatable, Sendable {
    let name: String
    let version: String?
    let summary: LocalizedStringResource
    let completeTextURL: URL
    let bundledTextResourceName: String?
    let textSHA256: String?
    let requiresExplicitAcceptance: Bool

    func verifiedBundledText(in bundle: Bundle) -> String? {
        guard let bundledTextResourceName,
              let textSHA256,
              let url = bundle.url(
                  forResource: bundledTextResourceName,
                  withExtension: "txt",
              ),
              let data = try? Data(contentsOf: url),
              SHA256.hash(data: data)
              .map({ String(format: "%02x", $0) })
              .joined() == textSHA256
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

nonisolated enum RawBrowseAIModelReleaseReadiness: Equatable, Sendable {
    case ready
    case blocked(reason: LocalizedStringResource)

    var isReady: Bool {
        if case .ready = self {
            true
        } else {
            false
        }
    }
}

/// Distribution metadata owned by RawBrowse rather than by the download host.
///
/// Keeping licence and provenance metadata in the application means the same
/// review flow works for GitHub model archives.
nonisolated struct CLIPModelDownloadDescriptor: Equatable, Identifiable, Sendable {
    let id: CLIPModelDownloadID
    let displayName: String
    let purpose: LocalizedStringResource
    let publisher: String
    let modelVersion: String
    let upstreamRevision: String?
    let resourceName: String
    let assetPackID: String
    let assetPackModelPath: String
    let upstreamSourceURL: URL
    let modelCardURL: URL
    let conversionInformationURL: URL?
    let expectedArchiveSHA256: String?
    let downloadByteCount: Int64?
    let installedByteCount: Int64?
    let licence: RawBrowseAIModelLicenceDescriptor
    let releaseReadiness: RawBrowseAIModelReleaseReadiness
}

nonisolated struct CLIPModelDownloadCatalog: Equatable, Sendable {
    let models: [CLIPModelDownloadDescriptor]

    func descriptor(
        for id: CLIPModelDownloadID,
    ) -> CLIPModelDownloadDescriptor? {
        models.first { $0.id == id }
    }

    static let prepared = Self(
        models: [
            CLIPModelDownloadDescriptor(
                id: .clipDataComp,
                displayName: "DataComp CLIP",
                purpose: "Image similarity, burst grouping, and semantic search.",
                publisher: "LAION / OpenCLIP",
                modelVersion: "ViT-B/32 256px, datacomp_s34b_b86k",
                upstreamRevision: "4afec35ffe57a943d569ff7ee888061830164da8",
                resourceName: "CLIP-DataComp",
                assetPackID: "rawbrowse-clip-datacomp",
                assetPackModelPath: "Models/CLIP-DataComp",
                upstreamSourceURL: requiredURL(
                    "https://huggingface.co/laion/CLIP-ViT-B-32-256x256-DataComp-s34B-b86K/tree/4afec35ffe57a943d569ff7ee888061830164da8",
                ),
                modelCardURL: requiredURL(
                    "https://huggingface.co/laion/CLIP-ViT-B-32-256x256-DataComp-s34B-b86K",
                ),
                conversionInformationURL: requiredURL(
                    "https://github.com/apple/coreai-models/tree/bffc38fe48f50e4e962ac9772b64a5b55a605286/models/clip",
                ),
                expectedArchiveSHA256: nil,
                downloadByteCount: 282_967_288,
                installedByteCount: 307_800_172,
                licence: RawBrowseAIModelLicenceDescriptor(
                    name: "MIT License",
                    version: nil,
                    summary: "The OpenCLIP/DataComp copyright and permission notice must accompany redistributed copies.",
                    completeTextURL: requiredURL(
                        "https://github.com/mlfoundations/open_clip/blob/main/LICENSE",
                    ),
                    bundledTextResourceName: "OpenCLIP-DataComp-MIT",
                    textSHA256: "6e355cc8399a572ed3db329d178a1188400fbbaed4397c28bd5b5fbac2696986",
                    requiresExplicitAcceptance: false,
                ),
                releaseReadiness: .ready,
            ),
            CLIPModelDownloadDescriptor(
                id: .sam3,
                displayName: "Meta SAM 3",
                purpose: "Local subject segmentation for Deep Review.",
                publisher: "Meta",
                modelVersion: "SAM 3",
                upstreamRevision: "3c879f39826c281e95690f02c7821c4de09afae7",
                resourceName: "SAM3",
                assetPackID: "rawbrowse-sam3",
                assetPackModelPath: "Models/SAM3",
                upstreamSourceURL: requiredURL(
                    "https://huggingface.co/facebook/sam3/tree/3c879f39826c281e95690f02c7821c4de09afae7",
                ),
                modelCardURL: requiredURL(
                    "https://huggingface.co/facebook/sam3/tree/3c879f39826c281e95690f02c7821c4de09afae7",
                ),
                conversionInformationURL: requiredURL(
                    "https://github.com/apple/coreai-models/tree/bffc38fe48f50e4e962ac9772b64a5b55a605286/models/sam3",
                ),
                expectedArchiveSHA256: nil,
                downloadByteCount: 1_542_689_933,
                installedByteCount: 1_667_570_378,
                licence: RawBrowseAIModelLicenceDescriptor(
                    name: "SAM License",
                    version: "November 19, 2025",
                    summary: "The SAM License contains redistribution, prohibited-use, trade-control, termination, warranty, liability, and indemnification terms.",
                    completeTextURL: requiredURL(
                        "https://huggingface.co/facebook/sam3/blob/3c879f39826c281e95690f02c7821c4de09afae7/LICENSE",
                    ),
                    bundledTextResourceName: "SAM3-SAM-License-2025-11-19",
                    textSHA256: "b08db9d32c687054e99cbd41eb1dad19c76936dfb9e2b58e186a01204d8be9ab",
                    requiresExplicitAcceptance: true,
                ),
                releaseReadiness: .ready,
            ),

        ],
    )

    static let production = Self(
        models: prepared.models.filter {
            [CLIPModelDownloadID.clipDataComp, .sam3].contains($0.id)
        },
    )

    private static func requiredURL(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            preconditionFailure("Invalid built-in model catalogue URL: \(string)")
        }
        return url
    }
}

extension CLIPModelDownloadDescriptor {
    var licenceName: String {
        licence.name
    }

    var licenceSummary: LocalizedStringResource {
        licence.summary
    }

    var licenceURL: URL {
        licence.completeTextURL
    }
}
