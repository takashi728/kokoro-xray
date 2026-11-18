;<?php http_response_code(403); /*
[main]
discussion = false
fileupload = false
sizelimit = 65536
defaultformatter = "plaintext"

[expire]
default = "1hour"

[expire_options]
5min = 300
1hour = 3600
1day = 86400

[traffic]
limit = 60

[purge]
limit = 60
batchsize = 100

[model]
class = Filesystem

[model_options]
dir = "/srv/data"
