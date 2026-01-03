#!/usr/bin/env node

/**********
 * Globals
 **********/

const PLUGIN_NAME = "FirebaseX plugin";
const PLUGIN_ID = "cordova-plugin-firebasex";

// No post-install variable processing needed for messaging-only plugin
// This file is kept as a placeholder for any future post-install processing

/**********
 * Main
 **********/
const main = function() {
    console.log(`${PLUGIN_NAME}: Post-install complete (messaging-only mode)`);
};
main();
