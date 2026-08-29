# Minimal static file server so Roblox's upload_image tool (which takes HTTP
# URLs, not local paths) can fetch the staged icons.
$root = "C:\Users\crocs\AppData\Local\Temp\iconweb"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:8731/")
$listener.Start()
Write-Output "serving $root on http://localhost:8731/"

while ($listener.IsListening) {
    try {
        $context = $listener.GetContext()
        $name = [System.IO.Path]::GetFileName($context.Request.Url.LocalPath)
        $file = Join-Path $root $name
        if (Test-Path $file) {
            $bytes = [System.IO.File]::ReadAllBytes($file)
            $context.Response.ContentType = "image/png"
            $context.Response.ContentLength64 = $bytes.Length
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        } else {
            $context.Response.StatusCode = 404
        }
        $context.Response.Close()
    } catch {
        # A dropped connection should never kill the server.
    }
}
