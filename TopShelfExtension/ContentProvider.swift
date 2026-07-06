//
//  ContentProvider.swift
//  TopShelfExtension
//
//  TV Services Extension for Top Shelf content — Apple TV+-style carousel.
//

import TVServices
import os.log

private let logger = Logger(subsystem: "com.gstudios.rivulet.TopShelfExtension", category: "ContentProvider")

class ContentProvider: TVTopShelfContentProvider {

    override func loadTopShelfContent() async -> TVTopShelfContent? {
        let items = TopShelfCache.shared.readItems()
        logger.info("TopShelf: Read \(items.count) items from cache")

        guard !items.isEmpty else {
            logger.warning("TopShelf: No items to display, returning nil")
            return nil
        }

        let carouselItems = items.compactMap { item -> TVTopShelfCarouselItem? in
            let cItem = TVTopShelfCarouselItem(identifier: item.ratingKey)

            // TVTopShelfCarouselItem has NO `title` property (that's only on the
            // sectioned item). Carousel text comes from contextTitle (the small
            // line above) + summary (the body). Map:
            //   episode -> contextTitle = show name, summary = episode name
            //   movie   -> summary = movie name, contextTitle = nil
            if let subtitle = item.subtitle, !subtitle.isEmpty {
                cItem.contextTitle = subtitle   // show name (episodes)
                cItem.summary = item.title      // episode name
            } else {
                cItem.summary = item.title       // movie name
            }

            // 16:9 backdrop art; fall back to the poster so an item is NEVER dropped.
            let art = item.wideImageURL.isEmpty ? item.imageURL : item.wideImageURL
            if let url = URL(string: art) {
                cItem.setImageURL(url, for: .screenScale1x)
                cItem.setImageURL(url, for: .screenScale2x)
            }

            // Deep link to resume playback.
            var components = URLComponents()
            components.scheme = "rivulet"
            components.host = "play"
            components.queryItems = [
                URLQueryItem(name: "ratingKey", value: item.ratingKey),
                URLQueryItem(name: "server", value: item.serverIdentifier)
            ]
            guard let actionURL = components.url else { return nil }
            cItem.playAction = TVTopShelfAction(url: actionURL)
            cItem.displayAction = cItem.playAction

            return cItem
        }

        guard !carouselItems.isEmpty else {
            logger.warning("TopShelf: No valid items after mapping, returning nil")
            return nil
        }

        logger.info("TopShelf: Returning \(carouselItems.count) carousel items")
        return TVTopShelfCarouselContent(style: .details, items: carouselItems)
    }
}
