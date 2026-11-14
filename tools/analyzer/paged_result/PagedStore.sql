PRAGMA page_size=4096;
PRAGMA journal_mode=DELETE;
PRAGMA synchronous=FULL;
PRAGMA foreign_keys=ON;
PRAGMA cache_size=-1024;
PRAGMA temp_store=MEMORY;
PRAGMA max_page_count=6144;
PRAGMA user_version=2;
CREATE TABLE profile(id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL CHECK(revision=2),aggregates INTEGER NOT NULL CHECK(aggregates IN(0,1)),transaction_rows INTEGER NOT NULL CHECK(transaction_rows IN(128,1024))) STRICT;
INSERT INTO profile VALUES(1,2,0,128);
CREATE TABLE scan_state(id INTEGER PRIMARY KEY CHECK(id=1),state INTEGER NOT NULL CHECK(state IN(0,1,2)),terminal BLOB) STRICT;
INSERT INTO scan_state VALUES(1,0,NULL);
CREATE TABLE observations_v2(
 id INTEGER PRIMARY KEY CHECK(id BETWEEN 0 AND 220000),
 parent INTEGER REFERENCES observations_v2(id),
 name BLOB NOT NULL CHECK(length(name)<=255 AND instr(name,x'00')=0 AND instr(name,x'2f')=0),
 kind INTEGER NOT NULL CHECK(kind BETWEEN 0 AND 4),
 identity BLOB CHECK(identity IS NULL OR length(identity)=16),
 links BLOB CHECK(links IS NULL OR length(links)=8),
 flags BLOB CHECK(flags IS NULL OR length(flags)=4),
 payload BLOB NOT NULL CHECK(length(payload)=52),
 CHECK((id=0 AND parent IS NULL AND length(name)=0 AND kind=1) OR
       (id>0 AND parent IS NOT NULL AND parent<id AND length(name)>0 AND name<>x'2e' AND name<>x'2e2e')),
 UNIQUE(parent,name)
) STRICT;
CREATE INDEX node_page ON observations_v2(parent,id);
CREATE INDEX object_identity ON observations_v2(identity,id) WHERE kind=0;
CREATE INDEX directory_identity ON observations_v2(identity,id) WHERE kind=1;
CREATE TRIGGER parent_is_directory BEFORE INSERT ON observations_v2 WHEN NEW.id>0 BEGIN
 SELECT CASE WHEN (SELECT kind FROM observations_v2 WHERE id=NEW.parent)<>1 OR
  EXISTS(SELECT 1 FROM observations_v2 p WHERE p.id=NEW.parent AND p.identity IS NOT NULL AND
    p.id<>(SELECT min(d.id) FROM observations_v2 d WHERE d.kind=1 AND d.identity=p.identity))
 THEN RAISE(ABORT,'parent_kind') END;
END;
INSERT INTO observations_v2 VALUES(0,NULL,x'',1,NULL,NULL,NULL,zeroblob(52));
CREATE TABLE rollups(node INTEGER PRIMARY KEY REFERENCES observations_v2(id),value BLOB NOT NULL CHECK(length(value)=140)) STRICT;
CREATE TABLE direct_totals(node INTEGER PRIMARY KEY REFERENCES observations_v2(id),value BLOB NOT NULL CHECK(length(value)=140)) STRICT;
CREATE TABLE direct_files(node INTEGER PRIMARY KEY REFERENCES observations_v2(id),value BLOB NOT NULL CHECK(length(value)=140)) STRICT;
CREATE TABLE type_totals(type INTEGER PRIMARY KEY CHECK(type BETWEEN 0 AND 12),value BLOB NOT NULL CHECK(length(value)=140)) STRICT;
CREATE TABLE folder_listing(node INTEGER PRIMARY KEY REFERENCES observations_v2(id),parent INTEGER NOT NULL REFERENCES observations_v2(id),name BLOB NOT NULL,logical BLOB NOT NULL CHECK(length(logical)=8),unknown BLOB NOT NULL CHECK(unknown IN(x'00',x'01'))) STRICT;
CREATE INDEX folder_order ON folder_listing(parent,unknown,logical DESC,name,node);
CREATE TABLE contexts(node INTEGER PRIMARY KEY REFERENCES observations_v2(id),role INTEGER NOT NULL CHECK(role BETWEEN 0 AND 8),project INTEGER) STRICT;
CREATE TABLE markers(node INTEGER PRIMARY KEY REFERENCES observations_v2(id),marker INTEGER NOT NULL CHECK(marker BETWEEN 0 AND 6)) STRICT;
CREATE TABLE groups(kind INTEGER NOT NULL CHECK(kind BETWEEN 0 AND 2),key INTEGER NOT NULL,value BLOB NOT NULL CHECK(length(value)=140),PRIMARY KEY(kind,key)) WITHOUT ROWID, STRICT;
CREATE INDEX group_rank ON groups(kind,substr(value,65,1),substr(value,41,8) DESC,key);
