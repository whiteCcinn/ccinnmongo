import BSON
import MongoWire

/// How a database command is put on the wire. Selected once per connection from the handshake.
protocol CommandWireProtocol: Sendable {
    func makeRequest(command: BSONDocument, database: String, secondaryOk: Bool, readPreference: BSONDocument?) -> WireRequest
    func replyDocument(from message: ReceivedMessage) throws -> BSONDocument
}

/// MongoDB ≤ 3.4: commands are queries against `<db>.$cmd` answered with `OP_REPLY`.
struct OpQueryCommandProtocol: CommandWireProtocol {
    func makeRequest(command: BSONDocument, database: String, secondaryOk: Bool, readPreference: BSONDocument?) -> WireRequest {
        var query = command
        if let readPreference {
            // mongos reads $readPreference from the wrapped form.
            query = ["$query": .document(command), "$readPreference": .document(readPreference)]
        }
        return .query(OpQuery(flags: secondaryOk || readPreference != nil ? [.secondaryOk] : [],
                              fullCollectionName: database + ".$cmd",
                              numberToSkip: 0,
                              numberToReturn: -1,
                              query: query))
    }

    func replyDocument(from message: ReceivedMessage) throws -> BSONDocument {
        guard case let .reply(reply) = message.reply else {
            throw MongoError(.protocolViolation, "Expected OP_REPLY to a legacy command")
        }
        guard var document = reply.documents.first else {
            throw MongoError(.protocolViolation, "Command reply contained no document")
        }
        if reply.flags.contains(.queryFailure) {
            // Normalise legacy failures to the modern {ok: 0, errmsg} shape.
            document["ok"] = .double(0)
            if document["errmsg"] == nil, let legacy = document["$err"] { document["errmsg"] = legacy }
        }
        return document
    }
}

/// MongoDB 3.6+: commands carry `$db` inside an `OP_MSG` body.
struct OpMsgCommandProtocol: CommandWireProtocol {
    func makeRequest(command: BSONDocument, database: String, secondaryOk: Bool, readPreference: BSONDocument?) -> WireRequest {
        var body = command
        body["$db"] = .string(database)
        if let readPreference {
            body["$readPreference"] = .document(readPreference)
        } else if secondaryOk {
            body["$readPreference"] = ["mode": "primaryPreferred"]
        }
        return .msg(OpMsg(body: body))
    }

    func replyDocument(from message: ReceivedMessage) throws -> BSONDocument {
        guard case let .msg(msg) = message.reply else {
            throw MongoError(.protocolViolation, "Expected OP_MSG reply")
        }
        return msg.body
    }
}
