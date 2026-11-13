import Testing
@testable import MongoKit

@Suite("Connection string")
struct ConnectionStringTests {
    @Test func parsesMultiHostURIWithCredentials() throws {
        let uri = try ConnectionString("mongodb://us%40r:p%3Ass@a.example:27017,[::1]:27018/app?replicaSet=rs0&authSource=admin")
        #expect(uri.scheme == .standard)
        #expect(uri.username == "us@r")
        #expect(uri.password == "p:ss")
        #expect(uri.hosts == [ServerAddress(host: "a.example", port: 27017), ServerAddress(host: "::1", port: 27018)])
        #expect(uri.hosts[1].description == "[::1]:27018")
        #expect(uri.database == "app")
        #expect(uri.replicaSet == "rs0")
        #expect(uri.authSource == "admin")
    }

    @Test func rejectsInvalidScheme() {
        #expect {
            try ConnectionString("http://localhost")
        } throws: { error in
            (error as? MongoError)?.message.contains("mongodb") == true
        }
    }

    @Test(arguments: [
        "mongodb://", "mongodb://host:0", "mongodb://host:70000", "mongodb://host:abc", "mongodb://a:b:c@host",
        "mongodb://host/db?tls", "mongodb+srv://a.example.com:27017", "mongodb+srv://a.example.com,b.example.com",
        "mongodb://user%ZZ@host", "mongodb://[::1", "mongodb://host/db?maxPoolSize=-1", "mongodb://host/db?tls=maybe",
        "mongodb://host/da\"tabase",
    ])
    func rejectsMalformedStrings(_ string: String) {
        #expect(throws: MongoError.self, "accepted \(string)") { try ConnectionString(string) }
    }

    @Test func defaultsAndAliases() throws {
        let uri = try ConnectionString("mongodb://localhost/?SSL=true&tlsAllowInvalidCertificates=true&readPreference=secondaryPreferred&directConnection=true&appName=Grove&maxPoolSize=7&connectTimeoutMS=2500")
        #expect(uri.hosts == [ServerAddress(host: "localhost", port: 27017)])
        #expect(uri.database == nil)
        #expect(uri.tls == true)
        #expect(uri.tlsAllowInvalidCertificates == true)
        #expect(uri.readPreference == .secondaryPreferred)
        #expect(uri.directConnection == true)
        #expect(uri.appName == "Grove")
        #expect(uri.maxPoolSize == 7)
        #expect(uri.connectTimeoutMS == 2500)
    }

    @Test func srvSchemeDefaultsTLS() throws {
        let uri = try ConnectionString("mongodb+srv://cluster0.example.com/db")
        #expect(uri.scheme == .srv)
        #expect(uri.tls == true)
        let explicit = try ConnectionString("mongodb+srv://cluster0.example.com/db?tls=false")
        #expect(explicit.tls == false)
    }

    @Test func unixDomainSocket() throws {
        let uri = try ConnectionString("mongodb://%2Ftmp%2Fmongodb-27017.sock/test")
        #expect(uri.hosts.first?.host == "/tmp/mongodb-27017.sock")
        #expect(uri.hosts.first?.isUnixSocket == true)
    }

    @Test func authMechanismProperties() throws {
        let uri = try ConnectionString("mongodb://u@h/?authMechanism=PLAIN&authMechanismProperties=SERVICE_NAME:mongodb,CANONICALIZE_HOST_NAME:true")
        #expect(uri.authMechanism == "PLAIN")
        #expect(uri.authMechanismProperties == ["SERVICE_NAME": "mongodb", "CANONICALIZE_HOST_NAME": "true"])
        #expect(uri.username == "u")
        #expect(uri.password == nil)
    }

    @Test func serializationRoundTripsAndRedacts() throws {
        let original = "mongodb://us%40r:p%3Ass@a.example:27017,[::1]:27018/app?replicaSet=rs0&authSource=admin"
        let uri = try ConnectionString(original)
        #expect(uri.description == original)
        #expect(try ConnectionString(uri.description) == uri)
        #expect(uri.redacted == "mongodb://us%40r:****@a.example:27017,[::1]:27018/app?replicaSet=rs0&authSource=admin")
        #expect(!uri.redacted.contains("p%3Ass"))
    }

    @Test func editingOptionsKeepsOrderAndCanonicalCase() throws {
        var uri = try ConnectionString("mongodb://h/?appname=a&TLS=true")
        #expect(uri.description == "mongodb://h:27017/?appName=a&tls=true")
        uri.setOption("replicaSet", "rs1")
        uri.setOption("tls", nil)
        #expect(uri.description == "mongodb://h:27017/?appName=a&replicaSet=rs1")
        uri.hosts = [ServerAddress(host: "db.internal", port: 27019)]
        uri.username = "x y"
        uri.password = "p@ss/word"
        #expect(uri.description == "mongodb://x%20y:p%40ss%2Fword@db.internal:27019/?appName=a&replicaSet=rs1")
    }

    @Test func impliesDirectConnection() throws {
        #expect(try ConnectionString("mongodb://a").prefersDirectConnection)
        #expect(!(try ConnectionString("mongodb://a,b").prefersDirectConnection))
        #expect(!(try ConnectionString("mongodb://a/?replicaSet=rs").prefersDirectConnection))
        #expect(try ConnectionString("mongodb://a,b/?directConnection=true").prefersDirectConnection == false)
        #expect(!(try ConnectionString("mongodb+srv://a.b.c").prefersDirectConnection))
    }
}
