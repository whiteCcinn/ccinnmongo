// Demo dataset used for screenshots and manual testing (works in the legacy mongo shell and mongosh).
//   docker exec <container> mongo -u grove -p grove-secret --authenticationDatabase admin /tmp/seed-demo.js
var shop = db.getSiblingDB('shop');
// MongoDB 2.6/3.2 shells have no NumberDecimal: fall back to doubles there.
var dec = function (text) { return typeof NumberDecimal === 'function' ? NumberDecimal(text) : parseFloat(text); };
shop.orders.drop();
shop.customers.drop();
shop.products.drop();
var cities = ['Kuala Lumpur', 'Penang', 'Johor Bahru', 'Singapore', 'Ipoh', 'Melaka'];
var statuses = ['pending', 'paid', 'shipped', 'delivered', 'cancelled'];
var names = ['Kopi', 'Teh Tarik', 'Nasi Lemak Kit', 'Durian Cake', 'Batik Shirt', 'Rattan Chair'];
var products = [];
for (var p = 0; p < 40; p++) {
  products.push({
    sku: 'SKU-' + (1000 + p), name: names[p % 6] + ' ' + (p + 1),
    price: dec(((p * 7.35) % 180 + 4.9).toFixed(2)), stock: NumberInt(p * 13 % 250),
    tags: ['local', p % 2 ? 'bestseller' : 'new'], dimensions: { w: p % 30 + 5, h: p % 20 + 3, unit: 'cm' }, active: p % 7 != 0
  });
}
shop.products.insert(products);
var customers = [];
for (var c = 0; c < 120; c++) {
  var doc = {
    name: 'Customer ' + c, email: 'customer' + c + '@example.my', city: cities[c % cities.length],
    joined: new Date(Date.UTC(2021, c % 12, (c % 27) + 1)), loyaltyPoints: NumberLong(c * 1337), vip: c % 9 == 0,
    address: { street: (c + 1) + ' Jalan Bukit Bintang', postcode: String(50000 + c), country: 'MY' }
  };
  if (c % 4 == 0) doc.phone = '+60 12-' + (1000000 + c * 37);
  doc.age = c % 5 == 0 ? 'unknown' : NumberInt(20 + c % 45);
  customers.push(doc);
}
shop.customers.insert(customers);
var orders = [];
for (var o = 0; o < 1500; o++) {
  var items = [];
  for (var i = 0; i < (o % 4) + 1; i++) {
    items.push({ sku: 'SKU-' + (1000 + (o * 7 + i) % 40), qty: NumberInt((o + i) % 5 + 1), price: dec((((o + i) * 3.1) % 90 + 2.5).toFixed(2)) });
  }
  orders.push({
    orderNo: NumberLong(100000 + o), customer: 'customer' + (o % 120) + '@example.my', status: statuses[o % statuses.length],
    total: Math.round(((o * 17.3) % 500 + 9.9) * 100) / 100, items: items,
    createdAt: new Date(Date.UTC(2024, o % 12, (o % 28) + 1, o % 24, o % 60)),
    channel: o % 3 == 0 ? 'mobile' : 'web', notes: o % 10 == 0 ? 'Leave at the guard house' : null
  });
}
shop.orders.insert(orders);
shop.orders.ensureIndex({ status: 1, createdAt: -1 });
shop.customers.ensureIndex({ email: 1 }, { unique: true });
print('seeded shop: ' + shop.orders.count() + ' orders');
