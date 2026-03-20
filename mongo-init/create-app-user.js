// Create a dedicated application user for Nightscout.
// This runs on first MongoDB startup only (when the data volume is empty).
// The root user is still available for admin tasks, but Nightscout connects
// with this limited-privilege user instead.

var appUser = process.env.MONGO_APP_USERNAME || 'nightscout';
var appPass = process.env.MONGO_APP_PASSWORD;
var dbName = process.env.MONGO_APP_DATABASE || 'nightscout';

if (!appPass) {
    print('WARNING: MONGO_APP_PASSWORD not set, skipping app user creation');
    print('Nightscout will need to connect as root (not recommended)');
} else {
    var db = db.getSiblingDB(dbName);

    // Create the user with readWrite on the nightscout database only
    db.createUser({
        user: appUser,
        pwd: appPass,
        roles: [
            { role: 'readWrite', db: dbName }
        ]
    });

    print('Created application user "' + appUser + '" with readWrite on "' + dbName + '"');
}
