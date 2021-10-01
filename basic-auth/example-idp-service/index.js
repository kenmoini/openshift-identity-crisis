const express = require('express');
const fs = require('fs')
const crypto = require("crypto")

const pathToUserConfigMap = '/opt/app-root/src/users.json'
const port = process.env.PORT || 8080;

const app = express();

var serviceOK = true

// Check for the users.json file
var configMapExists = false
fs.access(pathToUserConfigMap, fs.F_OK, (err) => {
  if (err) {
    return
  }

  //file exists
  configMapExists = true
});

var usersList;

// Read in ConfigMap or create a default JSON object
if (configMapExists) {

  fs.readFile(pathToUserConfigMap, 'utf8' , (err, data) => {
    if (err) {
      console.error(err)
      return
    }
    usersList = data
  });

} else {
  usersList = [
    // Default password is 'r3dh4t123!', SHA256
    {"sub": "user1", "passwordSHA": "cbc4381af9dc0855ab9ad709dcbc821bb854e09e8652465abf47801d3b89fc1a", "name": "User 1", "email": "user1@example.com"},
    {"sub": "user2", "passwordSHA": "cbc4381af9dc0855ab9ad709dcbc821bb854e09e8652465abf47801d3b89fc1a", "name": "User 2", "email": "user2@example.com"},
    {"sub": "user3", "passwordSHA": "cbc4381af9dc0855ab9ad709dcbc821bb854e09e8652465abf47801d3b89fc1a", "name": "User 3", "email": "user3@example.com"},
    {"sub": "user4", "passwordSHA": "cbc4381af9dc0855ab9ad709dcbc821bb854e09e8652465abf47801d3b89fc1a", "name": "User 4", "email": "user4@example.com"},
    {"sub": "user5", "passwordSHA": "cbc4381af9dc0855ab9ad709dcbc821bb854e09e8652465abf47801d3b89fc1a", "name": "User 5", "email": "user5@example.com"},
    {"sub": "user6", "passwordSHA": "cbc4381af9dc0855ab9ad709dcbc821bb854e09e8652465abf47801d3b89fc1a", "name": "User 6", "email": "user6@example.com"},
    {"sub": "user7", "passwordSHA": "cbc4381af9dc0855ab9ad709dcbc821bb854e09e8652465abf47801d3b89fc1a", "name": "User 7", "email": "user7@example.com"},
    {"sub": "user8", "passwordSHA": "cbc4381af9dc0855ab9ad709dcbc821bb854e09e8652465abf47801d3b89fc1a", "name": "User 8", "email": "user8@example.com"},
    {"sub": "user9", "passwordSHA": "cbc4381af9dc0855ab9ad709dcbc821bb854e09e8652465abf47801d3b89fc1a", "name": "User 9", "email": "user9@example.com"},
    {"sub": "user10", "passwordSHA": "cbc4381af9dc0855ab9ad709dcbc821bb854e09e8652465abf47801d3b89fc1a", "name": "User 10", "email": "user10@example.com"}
  ];
}

app.get('/', (req, res) => {
  if (serviceOK) {
    res.status(200).send('ok');
  };
});

app.get('/healthz', (req, res) => {
  if (serviceOK) {
    res.status(200).send('ok');
  };
});

app.get('/login', (req, res) => {
  var authHeader = req.headers.authorization;
  if (authHeader) {
    authHeaderParts = authHeader.split(' ')
    if (authHeaderParts[0] == "Basic") {
      var auth = new Buffer.from(authHeaderParts[1], 'base64').toString().split(':');
      var user = auth[0];
      var pass = auth[1];
      res.setHeader('Content-Type', 'application/json');
      
      // Find matching user
      var matchedUser = usersList.find(o => o.sub === user);
      if (matchedUser) {
        hashedPass = crypto.createHash("sha256").update(pass).digest("hex");
        if (hashedPass == matchedUser.passwordSHA) {
          res.status(200).send(JSON.stringify({"sub": matchedUser.sub, "name":matchedUser.name, "email": matchedUser.email}));
        } else {
          // Not a valid user credential pair
          res.status(401).send(JSON.stringify({"error": "invalid-auth-pair"}));
        };
      } else {
        // Not a valid user
        res.status(401).send(JSON.stringify({"error": "invalid-auth"}));
      }
    } else {
      // Not a Basic type auth header
      res.status(401).send(JSON.stringify({"error": "invalid-auth-header-type"}));
    }
  } else {
    // No auth headers provided with request
    res.status(401).send(JSON.stringify({"error": "no-auth-headers"}));
  }
});

app.listen(port, () => {
  console.log('Basic Auth NodeJS Service listening on port ' + port);
});