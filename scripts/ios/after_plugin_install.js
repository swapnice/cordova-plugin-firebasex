var helper = require("./helper");

module.exports = function(context) {
    // Ensure runpath search paths are configured correctly
    var xcodeProjectPath = helper.getXcodeProjectPath();
    helper.ensureRunpathSearchPath(context, xcodeProjectPath);
};
