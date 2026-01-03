var fs = require("fs");
var path = require("path");
var utilities = require("../lib/utilities");
var xcode = require("xcode");
var plist = require('plist');

var versionRegex = /\d+\.\d+\.\d+[^'"]*/,
    firebasePodRegex = /pod 'Firebase([^']+)', '(\d+\.\d+\.\d+[^'"]*)'/g,
    iosDeploymentTargetPodRegEx = /platform :ios, '(\d+\.\d+\.?\d*)'/;

// Public functions
module.exports = {

    /**
     * Used to get the path to the XCode project's .pbxproj file.
     */
    getXcodeProjectPath: function () {
      var appName = utilities.getAppName();
      // path used by cordova-ios 7.x and earlier
      var oldPath = path.join("platforms", "ios", appName + ".xcodeproj", "project.pbxproj");
      // path used by cordova-ios 8.x and later
      var newPath = path.join("platforms", "ios", "App.xcodeproj", "project.pbxproj");

      if (fs.existsSync(newPath)) {
          return newPath;
      }
      return oldPath;
    },

    ensureRunpathSearchPath: function(context, xcodeProjectPath){

        function addRunpathSearchBuildProperty(proj, build) {
            let LD_RUNPATH_SEARCH_PATHS = proj.getBuildProperty("LD_RUNPATH_SEARCH_PATHS", build);

            if (!Array.isArray(LD_RUNPATH_SEARCH_PATHS)) {
                LD_RUNPATH_SEARCH_PATHS = [LD_RUNPATH_SEARCH_PATHS];
            }

            LD_RUNPATH_SEARCH_PATHS.forEach(LD_RUNPATH_SEARCH_PATH => {
                if (!LD_RUNPATH_SEARCH_PATH) {
                    proj.addBuildProperty("LD_RUNPATH_SEARCH_PATHS", "\"$(inherited) @executable_path/Frameworks\"", build);
                }
                if (LD_RUNPATH_SEARCH_PATH.indexOf("@executable_path/Frameworks") == -1) {
                    var newValue = LD_RUNPATH_SEARCH_PATH.substr(0, LD_RUNPATH_SEARCH_PATH.length - 1);
                    newValue += ' @executable_path/Frameworks\"';
                    proj.updateBuildProperty("LD_RUNPATH_SEARCH_PATHS", newValue, build);
                }
                if (LD_RUNPATH_SEARCH_PATH.indexOf("$(inherited)") == -1) {
                    var newValue = LD_RUNPATH_SEARCH_PATH.substr(0, LD_RUNPATH_SEARCH_PATH.length - 1);
                    newValue += ' $(inherited)\"';
                    proj.updateBuildProperty("LD_RUNPATH_SEARCH_PATHS", newValue, build);
                }
            });
        }

        // Read and parse the XCode project (.pxbproj) from disk.
        // File format information: http://www.monobjc.net/xcode-project-file-format.html
        var xcodeProject = xcode.project(xcodeProjectPath);
        xcodeProject.parseSync();

        // Add search paths build property
        addRunpathSearchBuildProperty(xcodeProject, "Debug");
        addRunpathSearchBuildProperty(xcodeProject, "Release");

        // Finally, write the .pbxproj back out to disk.
        fs.writeFileSync(path.resolve(xcodeProjectPath), xcodeProject.writeSync());
    },

    applyPodsPostInstall: function(pluginVariables, iosPlatform){
        var podFileModified = false,
            podFilePath = path.resolve(iosPlatform.podFile);

        // check if file exists
        if(!fs.existsSync(podFilePath)){
            utilities.warn(`Podfile not found at ${podFilePath}`);
            return false;
        }

        var podFile = fs.readFileSync(podFilePath).toString(),
            DEBUG_INFORMATION_FORMAT = pluginVariables['IOS_STRIP_DEBUG'] && pluginVariables['IOS_STRIP_DEBUG'] === 'true' ? 'dwarf' : 'dwarf-with-dsym',
            iosDeploymentTargetMatch = podFile.match(iosDeploymentTargetPodRegEx),
            IPHONEOS_DEPLOYMENT_TARGET = iosDeploymentTargetMatch ? iosDeploymentTargetMatch[1] : null;

        if(!podFile.match('post_install')){
            podFile += `
post_install do |installer|
    installer.pods_project.targets.each do |target|
        target.build_configurations.each do |config|
            config.build_settings['DEBUG_INFORMATION_FORMAT'] = '${DEBUG_INFORMATION_FORMAT}'
            ${IPHONEOS_DEPLOYMENT_TARGET ? "config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '"+IPHONEOS_DEPLOYMENT_TARGET + "'" : ""}
            if target.respond_to?(:product_type) and target.product_type == "com.apple.product-type.bundle"
                config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
            end
        end
    end
end
                `;
            fs.writeFileSync(path.resolve(podFilePath), podFile);
            utilities.log('Applied post install block to Podfile');
            podFileModified = true;
        }
        return podFileModified;
    },

    applyPluginVarsToPlists: function(pluginVariables, iosPlatform){
        var googlePlistPath = path.resolve(iosPlatform.dest);
        if(!fs.existsSync(googlePlistPath)){
            utilities.warn(`Google plist not found at ${googlePlistPath}`);
            return;
        }

        var appPlistPath = path.resolve(iosPlatform.appPlist);
        if(!fs.existsSync(appPlistPath)){
            utilities.warn(`App plist not found at ${appPlistPath}`);
            return;
        }

        var entitlementsDebugPlistPath = path.resolve(iosPlatform.entitlementsDebugPlist);
        if(!fs.existsSync(entitlementsDebugPlistPath)){
            utilities.warn(`Entitlements debug plist not found at ${entitlementsDebugPlistPath}`);
            return;
        }

        var entitlementsReleasePlistPath = path.resolve(iosPlatform.entitlementsReleasePlist);
        if(!fs.existsSync(entitlementsReleasePlistPath)){
            utilities.warn(`Entitlements release plist not found at ${entitlementsReleasePlistPath}`);
            return;
        }

        var googlePlist = plist.parse(fs.readFileSync(googlePlistPath, 'utf8')),
            appPlist = plist.parse(fs.readFileSync(appPlistPath, 'utf8')),
            entitlementsDebugPlist = plist.parse(fs.readFileSync(entitlementsDebugPlistPath, 'utf8')),
            entitlementsReleasePlist = plist.parse(fs.readFileSync(entitlementsReleasePlistPath, 'utf8')),
            googlePlistModified = false,
            appPlistModified = false,
            entitlementsPlistsModified = false;

        if(pluginVariables['IOS_ENABLE_CRITICAL_ALERTS_ENABLED'] === 'true'){
            entitlementsDebugPlist["com.apple.developer.usernotifications.critical-alerts"] = true;
            entitlementsReleasePlist["com.apple.developer.usernotifications.critical-alerts"] = true;
            entitlementsPlistsModified = true;
        }

        if(typeof pluginVariables['FIREBASE_FCM_AUTOINIT_ENABLED'] !== 'undefined'){
            appPlist["FirebaseMessagingAutoInitEnabled"] = (pluginVariables['FIREBASE_FCM_AUTOINIT_ENABLED'] === "true") ;
            appPlistModified = true;
        }

        if(pluginVariables['IOS_FCM_ENABLED'] === 'false'){
            // Use GoogleService-Info.plist to pass this to the native part reducing noise in Info.plist.
            // A prefix should make it more clear that this is not the variable of the SDK.
            googlePlist["FIREBASEX_IOS_FCM_ENABLED"] = false;
            googlePlistModified = true;
            // FCM auto-init must be disabled early via the Info.plist in this case.
            appPlist["FirebaseMessagingAutoInitEnabled"] = false;
            appPlistModified = true;
        }

        if(googlePlistModified) fs.writeFileSync(path.resolve(iosPlatform.dest), plist.build(googlePlist));
        if(appPlistModified) fs.writeFileSync(path.resolve(iosPlatform.appPlist), plist.build(appPlist));
        if(entitlementsPlistsModified){
            fs.writeFileSync(path.resolve(iosPlatform.entitlementsDebugPlist), plist.build(entitlementsDebugPlist));
            fs.writeFileSync(path.resolve(iosPlatform.entitlementsReleasePlist), plist.build(entitlementsReleasePlist));
        }
    },

    applyPluginVarsToPodfile: function(pluginVariables, iosPlatform){
        var podFilePath = path.resolve(iosPlatform.podFile);

        // check if file exists
        if(!fs.existsSync(podFilePath)){
            utilities.warn(`Podfile not found at ${podFilePath}`);
            return false;
        }

        var podFileContents = fs.readFileSync(podFilePath, 'utf8'),
            podFileModified = false;

        if(pluginVariables['IOS_FIREBASE_SDK_VERSION']){
            if(pluginVariables['IOS_FIREBASE_SDK_VERSION'].match(versionRegex)){
                var matches = podFileContents.match(firebasePodRegex);
                if(matches){
                    matches.forEach((match) => {
                        var currentVersion = match.match(versionRegex)[0];
                        if(!match.match(pluginVariables['IOS_FIREBASE_SDK_VERSION'])){
                            podFileContents = podFileContents.replace(match, match.replace(currentVersion, pluginVariables['IOS_FIREBASE_SDK_VERSION']));
                            podFileModified = true;
                        }
                    });
                }
                if(podFileModified) utilities.log("Firebase iOS SDK version set to v"+pluginVariables['IOS_FIREBASE_SDK_VERSION']+" in Podfile");
            }else{
                throw new Error("The value \""+pluginVariables['IOS_FIREBASE_SDK_VERSION']+"\" for IOS_FIREBASE_SDK_VERSION is not a valid semantic version format")
            }
        }

        if(podFileModified) {
            fs.writeFileSync(path.resolve(iosPlatform.podFile), podFileContents);
        }

        return podFileModified;
    }
};

