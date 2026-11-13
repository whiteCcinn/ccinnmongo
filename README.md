# CcinnMongo

A native macOS client for MongoDB that works the same against **MongoDB 2.6 → 8.x**.

CcinnMongo has its own pure-Swift MongoDB stack (BSON, wire protocol, authentication), so it is not tied to the minimum server version of an official driver. It uses `OP_QUERY` for legacy servers and `OP_MSG` for MongoDB 3.6+.

