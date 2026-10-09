//
//  qrrefTests.swift
//  qrrefTests
//
//  Created by Петр Ломакин on 09.10.2026.
//

import Foundation
import Testing
@testable import qrref

struct QrLinkTests {

    @Test func parsesKeyFromUrlWithScheme() throws {
        let qr = try #require(QrLink.parse("https://qrref.io/?key=abc123"))
        #expect(qr.key == "abc123")
        #expect(!qr.bridge)
    }

    @Test func parsesKeyFromUrlWithoutSchemeLikeTheServerQR() throws {
        #expect(QrLink.parse("qrref.io/?key=AbC_d-9")?.key == "AbC_d-9")
    }

    @Test func acceptsKAliasAndPrefersKey() {
        #expect(QrLink.parse("https://x.ru/?k=zzz")?.key == "zzz")
        #expect(QrLink.parse("https://x.ru/?key=one&k=two")?.key == "one")
    }

    @Test func missingKeyGivesEmptyKey() {
        #expect(QrLink.parse("https://qrref.io/")?.key == "")
    }

    @Test func unsafeKeyIsDropped() {
        #expect(QrLink.parse("https://qrref.io/?key=../../etc")?.key == "")
        #expect(QrLink.parse("https://qrref.io/?key=a%2Fb")?.key == "")
    }

    @Test func detectsBridgeQR() throws {
        let qr = try #require(QrLink.parse("https://qrref.io/?a=first&b=second"))
        #expect(qr.bridge && qr.hasPair)
        #expect(qr.a == "first" && qr.b == "second")
        #expect(QrLink.parse("https://qrref.io/bridge?key=k1")?.bridge == true)
        #expect(QrLink.parse("https://qrref.io/?key=k1&bridge=1")?.bridge == true)
    }

    @Test func rejectsGarbage() {
        #expect(QrLink.parse("") == nil)
        #expect(QrLink.parse("   ") == nil)
        #expect(QrLink.parse("hello world") == nil)
    }

    @Test func buildsLinkThatParsesBack() {
        #expect(QrLink.build(serverURL: "https://qrref.io", key: "k") == "https://qrref.io/?key=k")
        #expect(QrLink.build(serverURL: "https://qrref.io/", key: "k") == "https://qrref.io/?key=k")
        #expect(QrLink.parse(QrLink.build(serverURL: "http://localhost:8080", key: "key"))?.key == "key")
    }

    @Test func webURLOnlyAcceptsASingleHttpLink() {
        #expect(QrLink.asWebURL("  https://example.com/a?b=1\n")?.absoluteString == "https://example.com/a?b=1")
        #expect(QrLink.asWebURL("http://example.com") != nil)
        #expect(QrLink.asWebURL("example.com") == nil)
        #expect(QrLink.asWebURL("see https://example.com") == nil)
        #expect(QrLink.asWebURL("javascript:alert(1)") == nil)
        #expect(QrLink.asWebURL("file:///etc/passwd") == nil)
        #expect(QrLink.asWebURL("https://") == nil)
    }

    @Test func normalizesServerURL() {
        #expect(QrLink.normalizeServerURL("qrref.io") == "https://qrref.io")
        #expect(QrLink.normalizeServerURL(" https://qrref.io/ ") == "https://qrref.io")
        #expect(QrLink.normalizeServerURL("http://localhost:8080") == "http://localhost:8080")
        #expect(QrLink.normalizeServerURL("") == nil)
        #expect(QrLink.normalizeServerURL("ftp://qrref.io") == nil)
        #expect(QrLink.normalizeServerURL("not a url") == nil)
    }

    @Test func generatedKeysAreSafe() {
        let key = KeyGenerator.generate()
        #expect(key.count == 20)
        #expect(QrLink.parse("https://x.ru/?key=\(key)")?.key == key)
    }
}

struct StompCodecTests {

    @Test func encodesSubscribeFrame() {
        let frame = StompCodec.encode("SUBSCRIBE", headers: [("id", "sub-0"), ("destination", "/topic/activity/k")])
        #expect(frame == "SUBSCRIBE\nid:sub-0\ndestination:/topic/activity/k\n\n\u{0}")
    }

    @Test func decodesMessageWithRussianBody() throws {
        let raw = "MESSAGE\nsubscription:sub-0\nmessage-id:abc-1\ndestination:/topic/activity/k\n"
            + "content-type:text/plain;charset=UTF-8\ncontent-length:12\n\nПривет, мир\u{0}"
        let frame = try #require(StompCodec.decode(raw))
        #expect(frame.command == "MESSAGE")
        #expect(frame.headers["subscription"] == "sub-0")
        #expect(frame.headers["destination"] == "/topic/activity/k")
        #expect(frame.body == "Привет, мир")
    }

    @Test func decodesConnectedWithoutBody() throws {
        let frame = try #require(StompCodec.decode("CONNECTED\nversion:1.2\nheart-beat:0,0\n\n\u{0}"))
        #expect(frame.command == "CONNECTED")
        #expect(frame.headers["version"] == "1.2")
        #expect(frame.body == "")
    }

    @Test func bodyMayContainBlankLinesAndColons() throws {
        let frame = try #require(StompCodec.decode("MESSAGE\nsubscription:s\n\nline1\n\nline3: value\u{0}"))
        #expect(frame.body == "line1\n\nline3: value")
    }

    @Test func heartBeatIsIgnored() {
        #expect(StompCodec.decode("\n") == nil)
        #expect(StompCodec.decode("") == nil)
    }

    @Test func unescapesHeadersAndKeepsFirstDuplicate() throws {
        let frame = try #require(StompCodec.decode("MESSAGE\ndestination:/a\\cb\nsubscription:one\nsubscription:two\n\n\u{0}"))
        #expect(frame.headers["destination"] == "/a:b")
        #expect(frame.headers["subscription"] == "one")
    }

    @Test func decodesCRLFFrames() throws {
        let frame = try #require(StompCodec.decode("MESSAGE\r\nsubscription:s\r\n\r\nbody\u{0}"))
        #expect(frame.headers["subscription"] == "s")
        #expect(frame.body == "body")
    }

    @Test func fileNameFromContentDisposition() {
        #expect(APIClient.fileName(fromContentDisposition: "attachment; filename=Foto_1.jpg") == "Foto_1.jpg")
        #expect(APIClient.fileName(fromContentDisposition: "attachment; filename=\"my file.txt\"") == "my file.txt")
        #expect(APIClient.fileName(fromContentDisposition: "attachment; filename=../../evil.sh") == "evil.sh")
        #expect(APIClient.fileName(fromContentDisposition: "attachment; filename=\"_____ ________.txt\"; filename*=UTF-8''%D0%9E%D1%82%D1%87%D1%91%D1%82%20%D1%82%D0%B5%D0%BB%D0%B5%D1%84%D0%BE%D0%BD%D0%B0.txt")
                == "Отчёт телефона.txt")
        #expect(APIClient.fileName(fromContentDisposition: nil) == "qrref-file")
        #expect(APIClient.fileName(fromContentDisposition: "attachment") == "qrref-file")
    }
}
