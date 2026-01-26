//
//  MockURLProtocol.swift
//  RivuletTests
//
//  URLProtocol subclass for intercepting network requests in tests
//

import Foundation

/// A URLProtocol subclass that intercepts network requests for testing
/// Usage:
/// 1. Register in setUp: URLProtocol.registerClass(MockURLProtocol.self)
/// 2. Configure mock: MockURLProtocol.mockResponses[url] = (data, response)
/// 3. Unregister in tearDown: URLProtocol.unregisterClass(MockURLProtocol.self)
class MockURLProtocol: URLProtocol {

    /// Maps URLs to mock responses (data, response)
    static var mockResponses: [URL: (Data, HTTPURLResponse)] = [:]

    /// Maps URLs to errors to throw
    static var mockErrors: [URL: Error] = [:]

    /// Records all requests made during the test
    static var requestHistory: [URLRequest] = []

    /// Reset all mocks between tests
    static func reset() {
        mockResponses = [:]
        mockErrors = [:]
        requestHistory = []
    }

    // MARK: - URLProtocol Implementation

    override class func canInit(with request: URLRequest) -> Bool {
        // Intercept all requests
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        // Record the request
        MockURLProtocol.requestHistory.append(request)

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        // Check for mock error first
        if let error = MockURLProtocol.mockErrors[url] {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        // Check for mock response
        if let (data, response) = MockURLProtocol.mockResponses[url] {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        // No mock configured - fail with error
        client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
    }

    override func stopLoading() {
        // Nothing to clean up
    }
}

// MARK: - Test Helpers

extension MockURLProtocol {

    /// Convenience method to set up a successful JSON response
    static func mockJSON(url: URL, json: [String: Any], statusCode: Int = 200) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        mockResponses[url] = (data, response)
    }

    /// Convenience method to set up a successful string response
    static func mockString(url: URL, content: String, statusCode: Int = 200, contentType: String = "text/plain") {
        let data = content.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType]
        )!
        mockResponses[url] = (data, response)
    }

    /// Convenience method to set up a data response
    static func mockData(url: URL, data: Data, statusCode: Int = 200, contentType: String = "application/octet-stream") {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType]
        )!
        mockResponses[url] = (data, response)
    }

    /// Convenience method to set up an HTTP error response
    static func mockHTTPError(url: URL, statusCode: Int) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        mockResponses[url] = (Data(), response)
    }

    /// Convenience method to set up a network error
    static func mockNetworkError(url: URL, error: URLError.Code) {
        mockErrors[url] = URLError(error)
    }
}
