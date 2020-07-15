//
//  EPUBParser.swift
//  r2-streamer-swift
//
//  Created by Olivier Körner on 08/12/2016.
//
//  Copyright 2018 Readium Foundation. All rights reserved.
//  Use of this source code is governed by a BSD-style license which is detailed
//  in the LICENSE file present in the project repository where this source code is maintained.
//

import R2Shared
import Fuzi

/// Epub related constants.
private struct EPUBConstant {
    /// Media Overlays URL.
    static let mediaOverlayURL = "media-overlay?resource="
}

/// Errors thrown during the parsing of the EPUB
///
/// - wrongMimeType: The mimetype file is missing or its content differs from
///                 "application/epub+zip" (expected).
/// - missingFile: A file is missing from the container at `path`.
/// - xmlParse: An XML parsing error occurred.
/// - missingElement: An XML element is missing.
public enum EPUBParserError: Error {
    /// The mimetype of the EPUB is not valid.
    case wrongMimeType
    case missingFile(path: String)
    case xmlParse(underlyingError: Error)
    /// Missing rootfile in `container.xml`.
    case missingRootfile
}

@available(*, deprecated, renamed: "EPUBParserError")
public typealias EpubParserError = EPUBParserError

extension EpubParser: Loggable {}

/// An EPUB container parser that extracts the information from the relevant
/// files and builds a `Publication` instance out of it.
final public class EpubParser: PublicationParser {
    
    public init() {}
    
    public func parse(file: File, fetcher: Fetcher, fallbackTitle: String, warnings: WarningLogger?) -> Publication.Components? {
        fatalError()
    }
    
    /// Parses the EPUB (file/directory) at `fileAtPath` and generate the
    /// corresponding `Publication` and `Container`.
    ///
    /// - Parameter url: The path to the epub file.
    /// - Returns: The Resulting publication, and a callback for parsing the
    ///            possibly DRM encrypted in the publication. The callback need
    ///            to be called by sending back the DRM object (or nil).
    ///            The point is to get DRM informations in the DRM object, and
    ///            inform the decypher() function in  the DRM object to allow
    ///            the fetcher to decypher encrypted resources.
    /// - Throws: `EPUBParserError.wrongMimeType`,
    ///           `EPUBParserError.xmlParse`,
    ///           `EPUBParserError.missingFile`
    static public func parse(at url: URL) throws -> (PubBox, PubParsingCallback) {
        var fetcher: Fetcher = try ArchiveFetcher(url: url)
        let opfHREF = try EPUBContainerParser(fetcher: fetcher).parseOPFHREF()
        let drm = scanForDRM(in: fetcher)

        // `Encryption` indexed by HREF.
        let encryptions = (try? EPUBEncryptionParser(fetcher: fetcher, drm: drm))?.parseEncryptions() ?? [:]

        // Extracts metadata and links from the OPF.
        let components = try OPFParser(fetcher: fetcher, opfHREF: opfHREF, encryptions: encryptions).parsePublication()
        let metadata = components.metadata
        let links = components.readingOrder + components.resources
        
        let userProperties = UserProperties()
        let lcpDecryptor = LCPDecryptor(drm: drm)

        fetcher = TransformingFetcher(fetcher: fetcher, transformers: [
            lcpDecryptor?.decrypt(resource:),
            EPUBDeobfuscator(publicationId: metadata.identifier ?? "").deobfuscate(resource:),
            EPUBHTMLInjector(metadata: components.metadata, userProperties: userProperties).inject(resource:)
        ].compactMap { $0 })

        let publication = Publication(
            manifest: Manifest(
                metadata: metadata,
                readingOrder: components.readingOrder,
                resources: components.resources,
                subcollections: parseCollections(in: fetcher, links: links)
            ),
            fetcher: fetcher,
            servicesBuilder: PublicationServicesBuilder(
                positions: EPUBPositionsService.createFactory()
            ),
            format: .epub,
            formatVersion: components.version
        )
        
        publication.userProperties = userProperties
        publication.userSettingsUIPreset = publication.contentLayout.userSettingsPreset

        let container = PublicationContainer(
            publication: publication,
            path: url.path,
            mimetype: MediaType.epub.string,
            drm: drm
        )

        func parseRemainingResource(protectedBy drm: DRM?) throws {
            container.drm = drm
            lcpDecryptor?.license = drm?.license
        }
        
        return ((publication, container), parseRemainingResource)
    }
    
    static private func parseCollections(in fetcher: Fetcher, links: [Link]) -> [String: [PublicationCollection]] {
        var collections = parseNavigationDocument(in: fetcher, links: links)
        if collections["toc"]?.first?.links.isEmpty != false {
            // Falls back on the NCX tables.
            collections.merge(parseNCXDocument(in: fetcher, links: links), uniquingKeysWith: { first, second in first})
        }
        return collections
    }

    // MARK: - Internal Methods.

    /// WIP, currently only LCP.
    /// Scan Container (but later Publication too probably) to know if any DRM
    /// are protecting the publication.
    ///
    /// - Parameter in: The Publication's Container.
    /// - Returns: The DRM if any found.
    private static func scanForDRM(in fetcher: Fetcher) -> DRM? {
        // Check if a LCP license file is present in the package.
        if ((try? fetcher.readData(at: "/META-INF/license.lcpl")) != nil) {
            return DRM(brand: .lcp)
        }
        return nil
    }

    /// Attempt to fill the `Publication`'s `tableOfContent`, `landmarks`, `pageList` and `listOfX` links collections using the navigation document.
    private static func parseNavigationDocument(in fetcher: Fetcher, links: [Link]) -> [String: [PublicationCollection]] {
        // Get the link in the readingOrder pointing to the Navigation Document.
        guard let navLink = links.first(withRel: "contents"),
            let navDocumentData = try? fetcher.readData(at: navLink.href) else
        {
            return [:]
        }
        
        // Get the location of the navigation document in order to normalize href paths.
        let navigationDocument = NavigationDocumentParser(data: navDocumentData, at: navLink.href)
        
        var collections: [String: [PublicationCollection]] = [:]
        func addCollection(_ type: NavigationDocumentParser.NavType, role: String) {
            let links = navigationDocument.links(for: type)
            if !links.isEmpty {
                collections[role] = [PublicationCollection(links: links)]
            }
        }

        addCollection(.tableOfContents, role: "toc")
        addCollection(.pageList, role: "pageList")
        addCollection(.landmarks, role: "landmarks")
        addCollection(.listOfAudiofiles, role: "loa")
        addCollection(.listOfIllustrations, role: "loi")
        addCollection(.listOfTables, role: "lot")
        addCollection(.listOfVideos, role: "lov")
        
        return collections
    }

    /// Attempt to fill `Publication.tableOfContent`/`.pageList` using the NCX
    /// document. Will only modify the Publication if it has not be filled
    /// previously (using the Navigation Document).
    private static func parseNCXDocument(in fetcher: Fetcher, links: [Link]) -> [String: [PublicationCollection]] {
        // Get the link in the readingOrder pointing to the NCX document.
        guard let ncxLink = links.first(withMediaType: .ncx),
            let ncxDocumentData = try? fetcher.readData(at: ncxLink.href) else
        {
            return [:]
        }
        
        let ncx = NCXParser(data: ncxDocumentData, at: ncxLink.href)
        
        var collections: [String: [PublicationCollection]] = [:]
        func addCollection(_ type: NCXParser.NavType, role: String) {
            let links = ncx.links(for: type)
            if !links.isEmpty {
                collections[role] = [PublicationCollection(links: links)]
            }
        }

        addCollection(.tableOfContents, role: "toc")
        addCollection(.pageList, role: "pageList")
        
        return collections
    }

    /// Parse the mediaOverlays informations contained in the ressources then
    /// parse the associted SMIL files to populate the MediaOverlays objects
    /// in each of the ReadingOrder's Links.
    private static func parseMediaOverlay(from fetcher: Fetcher, to publication: inout Publication) throws {
        // FIXME: For now we don't fill the media-overlays anymore, since it was only half implemented and the API will change
//        let mediaOverlays = publication.resources.filter(byType: .smil)
//
//        guard !mediaOverlays.isEmpty else {
//            log(.info, "No media-overlays found in the Publication.")
//            return
//        }
//        for mediaOverlayLink in mediaOverlays {
//            let node = MediaOverlayNode()
//
//            guard let smilData = try? fetcher.data(at: mediaOverlayLink.href),
//                let smilXml = try? XMLDocument(data: smilData) else
//            {
//                throw OPFParserError.invalidSmilResource
//            }
//
//            smilXml.definePrefix("smil", forNamespace: "http://www.w3.org/ns/SMIL")
//            smilXml.definePrefix("epub", forNamespace: "http://www.idpf.org/2007/ops")
//            guard let body = smilXml.firstChild(xpath: "./smil:body") else {
//                continue
//            }
//
//            node.role.append("section")
//            if let textRef = body.attr("textref") { // Prevent the crash on the japanese book
//                node.text = normalize(base: mediaOverlayLink.href, href: textRef)
//            }
//            // get body parameters <par>a
//            let href = mediaOverlayLink.href
//            SMILParser.parseParameters(in: body, withParent: node, base: href)
//            SMILParser.parseSequences(in: body, withParent: node, publicationReadingOrder: &publication.readingOrder, base: href)
            // "/??/xhtml/mo-002.xhtml#mo-1" => "/??/xhtml/mo-002.xhtml"
            
//            guard let baseHref = node.text?.components(separatedBy: "#")[0],
//                let link = publication.readingOrder.first(where: { baseHref.contains($0.href) }) else
//            {
//                continue
//            }
//            link.mediaOverlays.append(node)
//            link.properties.mediaOverlay = EPUBConstant.mediaOverlayURL + link.href
//        }
    }

}
