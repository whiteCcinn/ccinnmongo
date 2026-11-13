import Foundation
import MongoKit
import Testing
@testable import CcinnMongoKit

@Suite("Connection form ⇄ URI")
struct ConnectionFormTests {
    @Test func formReflectsURI() throws {
        let form = try ConnectionForm(uri: "mongodb://admin:pw@db1:27018,db2/sales?replicaSet=rs0&authSource=admin&authMechanism=SCRAM-SHA-1&tls=true&tlsAllowInvalidCertificates=true&readPreference=secondary&appName=X&w=majority")
        #expect(form.hosts.map(\.host) == ["db1", "db2"])
        #expect(form.hosts.map(\.port) == [27018, 27017])
        #expect(form.username == "admin")
        #expect(form.password == "pw")
        #expect(form.authentication == .scramSHA1)
        #expect(form.authSource == "admin")
        #expect(form.defaultDatabase == "sales")
        #expect(form.replicaSet == "rs0")
        #expect(form.tlsEnabled)
        #expect(form.tlsAllowInvalidCertificates)
        #expect(form.readPreference == .secondary)
        #expect(form.appName == "X")
        #expect(form.extraOptions == [ConnectionString.Option(name: "w", value: "majority")])
    }

    @Test func changingPortUpdatesURI() throws {
        var form = try ConnectionForm(uri: "mongodb://localhost:27017/")
        form.hosts[0].port = 27999
        #expect(form.uri.description == "mongodb://localhost:27999/")
    }

    @Test func roundTripPreservesEverything() throws {
        let uri = "mongodb://u%40x:p%3As@a:1,b:2/db?replicaSet=rs&authSource=admin&authMechanism=SCRAM-SHA-256&tls=true&tlsCAFile=%2Ftmp%2Fca.pem&directConnection=false&readPreference=nearest&appName=App&connectTimeoutMS=5000&w=1"
        let form = try ConnectionForm(uri: uri)
        let rebuilt = try ConnectionString(form.uri.description)
        let original = try ConnectionString(uri)
        #expect(rebuilt.hosts == original.hosts)
        #expect(rebuilt.username == original.username)
        #expect(rebuilt.password == original.password)
        #expect(rebuilt.database == original.database)
        for name in ["replicaSet", "authSource", "authMechanism", "tls", "tlsCAFile", "directConnection", "readPreference", "appName", "connectTimeoutMS", "w"] {
            #expect(rebuilt.option(name) == original.option(name), "\(name)")
        }
    }

    @Test func srvFormHasNoPorts() throws {
        var form = try ConnectionForm(uri: "mongodb+srv://cluster0.abc.mongodb.net/")
        #expect(form.isSRV)
        form.hosts[0].host = "cluster1.abc.mongodb.net"
        #expect(form.uri.description == "mongodb+srv://cluster1.abc.mongodb.net/")
    }

    @Test func noAuthenticationClearsCredentials() throws {
        var form = try ConnectionForm(uri: "mongodb://u:p@h/?authSource=admin&authMechanism=PLAIN")
        form.authentication = .none
        let uri = form.uri
        #expect(uri.username == nil)
        #expect(uri.password == nil)
        #expect(uri.option("authMechanism") == nil)
        #expect(uri.option("authSource") == nil)
    }
}
