/// Words offered by the query editors' completion.
public enum CompletionCatalog {
    public static let queryOperators = [
        "$eq", "$ne", "$gt", "$gte", "$lt", "$lte", "$in", "$nin", "$and", "$or", "$nor", "$not", "$exists", "$type",
        "$regex", "$options", "$elemMatch", "$size", "$all", "$mod", "$text", "$search", "$where", "$expr", "$jsonSchema",
        "$geoWithin", "$geoIntersects", "$near", "$nearSphere", "$bitsAllSet", "$bitsAnySet", "$comment",
    ]

    public static let updateOperators = [
        "$set", "$unset", "$inc", "$mul", "$rename", "$min", "$max", "$currentDate", "$setOnInsert", "$push", "$pull",
        "$pullAll", "$addToSet", "$pop", "$each", "$slice", "$sort", "$position", "$bit",
    ]

    public static let expressionOperators = [
        "$sum", "$avg", "$min", "$max", "$first", "$last", "$push", "$addToSet", "$count", "$add", "$subtract",
        "$multiply", "$divide", "$mod", "$concat", "$substr", "$toLower", "$toUpper", "$cond", "$ifNull", "$switch",
        "$dateToString", "$year", "$month", "$dayOfMonth", "$hour", "$size", "$filter", "$map", "$reduce",
        "$arrayElemAt", "$in", "$toString", "$toInt", "$toDouble", "$toDate", "$objectToArray", "$mergeObjects",
    ]

    public static let constructors = [
        "ObjectId()", "ISODate()", "NumberLong()", "NumberInt()", "NumberDecimal()", "Timestamp()", "BinData()",
        "UUID()", "MinKey", "MaxKey", "RegExp()",
    ]

    public static var allOperators: [String] {
        var seen = Set<String>()
        return (queryOperators + updateOperators + expressionOperators + StageCatalog.stages.map(\.name)).filter { seen.insert($0).inserted }
    }
}
