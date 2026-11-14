// Filename suffix hints. Differentially checked against AnalysisFileType.
fn file_type(name:&[u8])->usize {file_type_revision(name,CLASSIFICATION_REVISION)}
fn file_type_revision(name:&[u8],revision:u64)->usize {
    let Some(dot)=name.iter().rposition(|b|*b==46) else{return 0;};
    if dot==0{return 0;}let suffix=&name[dot+1..];
    if suffix.is_empty() || suffix.len()>16 || suffix.iter().any(|b|*b>=128){return 0;}
    let mut lower=[0u8;16];for (i,b) in suffix.iter().enumerate(){lower[i]=b.to_ascii_lowercase();}
    if revision==4 {
        match &lower[..suffix.len()] {
            b"csv"|b"tsv"|b"parquet"|b"arrow"|b"arrows"|b"feather"|b"orc"|b"avro"|b"npy"|b"npz"|b"h5"|b"hdf5"|b"fits"|b"netcdf"|b"rds"|b"rdata"=>return 16,
            _=>{}
        }
    }
    if revision>=3 {
        match &lower[..suffix.len()] {
            b"car"|b"nib"|b"rsrc"=>return 15,
            b"plist"|b"strings"|b"stringsdict"|b"entitlements"|b"xcconfig"|b"xib"|b"storyboard"=>return 2,
            b"icns"=>return 5,
            _=>{}
        }
    }
    match &lower[..suffix.len()] {b"pdf"|b"doc"|b"docx"|b"pages"|b"rtf"|b"rtfd"|b"odt"|b"epub"=>1,b"txt"|b"md"|b"markdown"|b"rst"|b"log"|b"csv"|b"tsv"|b"json"|b"jsonl"|b"xml"|b"yaml"|b"yml"|b"toml"|b"ini"|b"conf"|b"cfg"|b"swift"|b"rs"|b"c"|b"h"|b"cpp"|b"hpp"|b"m"|b"mm"|b"py"|b"pyi"|b"dart"|b"js"|b"jsx"|b"ts"|b"tsx"|b"html"|b"css"|b"scss"|b"sh"|b"bash"|b"zsh"|b"go"|b"java"|b"kt"|b"kts"|b"sql"=>2,b"xls"|b"xlsx"|b"xlsm"|b"numbers"|b"ods"=>3,b"ppt"|b"pptx"|b"key"|b"odp"=>4,b"jpg"|b"jpeg"|b"png"|b"gif"|b"heic"|b"heif"|b"webp"|b"avif"|b"tif"|b"tiff"|b"bmp"|b"svg"|b"ico"|b"dng"|b"raw"|b"psd"=>5,b"mp4"|b"m4v"|b"mov"|b"mkv"|b"avi"|b"webm"|b"mpeg"|b"mpg"|b"mts"|b"m2ts"=>6,b"mp3"|b"m4a"|b"aac"|b"wav"|b"aiff"|b"aif"|b"flac"|b"ogg"|b"opus"|b"alac"=>7,b"zip"|b"7z"|b"rar"|b"tar"|b"gz"|b"bz2"|b"xz"|b"zst"|b"tgz"|b"tbz2"|b"txz"|b"vpk"|b"pak"|b"pck"=>8,b"dmg"|b"iso"|b"img"|b"sparseimage"|b"toast"=>9,b"vmdk"|b"vdi"|b"vhd"|b"vhdx"|b"qcow"|b"qcow2"|b"hdd"=>10,b"gguf"|b"ggml"|b"safetensors"|b"onnx"|b"mlmodel"|b"tflite"=>11,b"ttf"|b"otf"|b"woff"|b"woff2"|b"ttc"=>12,b"db"|b"sqlite"|b"sqlite3"|b"mdb"|b"accdb"|b"duckdb"|b"db-wal"|b"db-shm"|b"sqlite-wal"|b"sqlite-shm"|b"sqlite3-wal"|b"sqlite3-shm"=>13,b"dylib"|b"so"|b"a"|b"o"|b"obj"|b"dll"|b"exe"|b"class"|b"jar"|b"wasm"|b"metallib"|b"pyc"=>14,_=>0}
}
