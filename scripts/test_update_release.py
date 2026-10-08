import base64, io, json, plistlib, tempfile, unittest, zipfile
from pathlib import Path
from publish_codex_update import validate_request, make_feed, inspect_archive, NS, BUNDLE_ID, FEED

class UpdateReleaseTests(unittest.TestCase):
    def setUp(self):
        self.req={'version':'1.5.0','build':100,'run_id':1,'source_sha':'a'*40,'archive_sha256':'b'*64}
    def test_request_validation(self):
        validate_request(self.req)
        for key,value in [('version','1;rm -rf /'),('build',40),('source_sha','main'),('run_id',0),('signature','bad')]:
            with self.assertRaises((ValueError,TypeError)):
                validate_request(dict(self.req,**{key:value}))
    def test_feed_is_escaped_scoped_and_monotonic(self):
        previous=b'<rss version="2.0"><channel><title>Compositor AI</title></channel></rss>'
        req=dict(self.req,notes='<script>not markup & not executable</script>')
        sig=base64.b64encode(b'a'*64).decode()
        feed=make_feed(previous,req,sig,1024,'26.0')
        self.assertIn(b'Waynelee2001/Compositor/releases/download/ai-v1.5.0-b100/Compositor-AI-arm64.zip',feed)
        self.assertIn(b'&lt;script&gt;',feed)
        self.assertNotIn(b'robbietilton',feed)
        with self.assertRaises(ValueError): make_feed(feed,req,sig,1024,'26.0')
        make_feed(feed,dict(req,build=101),sig,1024,'26.0')
    def test_wrong_archive_digest_fails_before_unpacking(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'bad.zip';p.write_bytes(b'not an archive')
            with self.assertRaises(ValueError): inspect_archive(p,self.req,'key')
if __name__=='__main__': unittest.main()
