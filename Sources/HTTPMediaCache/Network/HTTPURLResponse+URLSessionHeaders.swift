//
//  HTTPURLResponse+URLSessionHeaders.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/12.
//

import Foundation

extension HTTPURLResponse {
    var urlSessionHeaderDictionary: [String: String] {
        allHeaderFields.reduce(into: [String: String]()) { result, header in
            guard let name = header.key as? String else {
                return
            }
            result[name] = "\(header.value)"
        }
    }
}
