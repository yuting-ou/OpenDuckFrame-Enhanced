import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class ReleaseConfigurationTests(unittest.TestCase):
    def test_enhanced_release_never_inherits_upstream_update_channel(self):
        config = json.loads((ROOT / "Distribution/sparkle.json").read_text())
        self.assertEqual(config["repository"], "yuting-ou/OpenDuckFrame-Enhanced")
        self.assertEqual(config["keychainAccount"], "app.openduckframe.OpenDuckFrame.enhanced")
        feed = config["feedUrl"]
        key = config["publicKey"]
        self.assertTrue(not feed and not key, "Enhanced releases must keep Sparkle disabled until an own feed exists")
        if feed:
            self.assertTrue(feed.startswith("https://yuting-ou.github.io/OpenDuckFrame-Enhanced/"))

    def test_application_links_to_enhanced_repository(self):
        project = (ROOT / "Apps/Mac/project.yml").read_text()
        self.assertTrue('ODFRepositoryURL: "https://github.com/yuting-ou/OpenDuckFrame-Enhanced"' in project,
                        "Application repository link must target the Enhanced fork")
        self.assertNotIn('ODFRepositoryURL: "https://github.com/Jun-bao/OpenDuckFrame"', project)


if __name__ == "__main__":
    unittest.main()
