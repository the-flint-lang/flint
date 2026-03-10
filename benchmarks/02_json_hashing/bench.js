const fs = require('fs');

const db = JSON.parse(fs.readFileSync('bench_data.json', 'utf8'));
console.log(db["user_key_499999"]);