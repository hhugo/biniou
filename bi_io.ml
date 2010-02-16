(* $Id$ *)

open Printf

open Bi_buf

type node_tag = int

let int8_tag = 1
let int16_tag = 2
let int32_tag = 3
let int64_tag = 4
let int128_tag = 5
let float64_tag = 12
let uvint_tag = 16
let svint_tag = 17
let string_tag = 18
let array_tag = 19
let tuple_tag = 20
let record_tag = 21
let num_variant_tag = 22
let variant_tag = 23
let tuple_table_tag = 24
let record_table_tag = 25 
let matrix_tag = 26

type hash = int

(*
  Data tree, for testing purposes.
*)
type tree =
    [ `Int8 of int
    | `Int16 of int
    | `Int32 of Int32.t
    | `Int64 of Int64.t
    | `Int128 of string
    | `Float64 of float
    | `Uvint of int
    | `Svint of int
    | `String of string
    | `Array of (node_tag * tree array)
    | `Tuple of tree array
    | `Record of (string * hash * tree) array
    | `Num_variant of (int * tree option)
    | `Variant of (string * hash * tree option)
    | `Tuple_table of (node_tag array * tree array array)
    | `Record_table of ((string * hash * node_tag) array * tree array array)
    | `Matrix of (node_tag * int * tree array array) ]
    
(* extend sign bit *)
let make_signed x =
  if x > 0x3FFFFFFF then x - (1 lsl 31) else x

(*
  Same function as the one used for OCaml variants and object methods.
*)
let hash_name s =
  let accu = ref 0 in
  for i = 0 to String.length s - 1 do
    accu := 223 * !accu + Char.code s.[i]
  done;
  (* reduce to 31 bits *)
  accu := !accu land (1 lsl 31 - 1);
  (* make it signed for 64 bits architectures *)
  make_signed !accu


(*
  Structure of a hashtag: 4 bytes,

  argbit 7bits 8bits 8bits 8bits
         +---------------------+
              31-bit hash

  argbit = 1 iff hashtag is followed by an argument, this is always 1 for
           record fields.

*)
let write_hashtag buf h has_arg =
  let h = h land 0x7fffffff in
  let pos = Bi_buf.alloc buf 4 in
  let s = buf.s in
  s.[pos+3] <- Char.chr (h land 0xff);
  let h = h lsr 8 in
  s.[pos+2] <- Char.chr (h land 0xff);
  let h = h lsr 8 in
  s.[pos+1] <- Char.chr (h land 0xff);
  let h = h lsr 8 in
  s.[pos] <- Char.chr (
    if has_arg then h lor 0x80
    else h
  )

let read_hashtag s pos cont =
  let i = !pos in
  if i + 4 > String.length s then
    Bi_util.error "Corrupted data (hashtag)";
  let x0 = Char.code s.[i] in
  let has_arg = x0 >= 0x80 in
  let x1 = (x0 land 0x7f) lsl 24 in
  let x2 = (Char.code s.[i+1]) lsl 16 in
  let x3 = (Char.code s.[i+2]) lsl 8 in
  let x4 = Char.code s.[i+3] in
  pos := !pos + 4;
  let h = make_signed (x1 lor x2 lor x3 lor x4) in
  
  cont s pos h has_arg


let read_field_hashtag s pos =
  let i = !pos in
  if i + 4 > String.length s then
    Bi_util.error "Corrupted data (truncated field hashtag)";
  let x0 = Char.code s.[i] in
  if x0 < 0x80 then
    Bi_util.error "Corrupted data (invalid field hashtag)";
  let x1 = (x0 land 0x7f) lsl 24 in
  let x2 = (Char.code s.[i+1]) lsl 16 in
  let x3 = (Char.code s.[i+2]) lsl 8 in
  let x4 = Char.code s.[i+3] in
  pos := !pos + 4;
  make_signed (x1 lor x2 lor x3 lor x4)
  

type int7 = int

let write_numtag buf i has_arg =
  if i < 0 || i > 0x7f then
    Bi_util.error "Corrupted data (invalid numtag)";
  let x =
    if has_arg then i lor 0x80
    else i
  in
  Bi_buf.add_char buf (Char.chr x)

let read_numtag s pos cont =
  if !pos >= String.length s then
    Bi_util.error "Corrupted data (numtag)";
  let x = Char.code s.[!pos] in
  incr pos;
  let has_arg = x >= 0x80 in
  cont s pos (x land 0x7f) has_arg

let make_unhash l =
  let tbl = Hashtbl.create (4 * List.length l) in
  List.iter (
    fun s ->
      let h = hash_name s in
      try 
	let s' = Hashtbl.find tbl h in
	if s <> s' then
	  failwith (
	    sprintf
	      "Bi_io.make_unhash: \
               %S and %S have the same hash, please pick another name"
	      s s'
	  )
      with Not_found -> Hashtbl.add tbl h s
  ) l;
  fun h ->
    try Hashtbl.find tbl h
    with Not_found -> sprintf "#%08lx" (Int32.of_int h)


let write_tag buf x =
  Bi_buf.add_char buf (Char.chr x)

let write_untagged_int8 buf x =
  Bi_buf.add_char buf (Char.chr x)

let write_untagged_int16 buf x =
  Bi_buf.add_char buf (Char.chr (x lsr 8));
  Bi_buf.add_char buf (Char.chr (x land 0xff))

let write_untagged_int32 buf x =
  let high = Int32.to_int (Int32.shift_right_logical x 16) in
  Bi_buf.add_char buf (Char.chr (high lsr 8));
  Bi_buf.add_char buf (Char.chr (high land 0xff));
  let low = Int32.to_int x in
  Bi_buf.add_char buf (Char.chr ((low lsr 8) land 0xff));
  Bi_buf.add_char buf (Char.chr (low land 0xff))
    
let write_untagged_int64 buf x =
  let x4 = Int64.to_int (Int64.shift_right_logical x 48) in
  Bi_buf.add_char buf (Char.chr (x4 lsr 8));
  Bi_buf.add_char buf (Char.chr (x4 land 0xff));
  let x3 = Int64.to_int (Int64.shift_right_logical x 32) in
  Bi_buf.add_char buf (Char.chr ((x3 lsr 8) land 0xff));
  Bi_buf.add_char buf (Char.chr (x3 land 0xff));
  let x2 = Int64.to_int (Int64.shift_right_logical x 16) in
  Bi_buf.add_char buf (Char.chr ((x2 lsr 8) land 0xff));
  Bi_buf.add_char buf (Char.chr (x2 land 0xff));
  let x1 = Int64.to_int x in
  Bi_buf.add_char buf (Char.chr ((x1 lsr 8) land 0xff));
  Bi_buf.add_char buf (Char.chr (x1 land 0xff))

let write_untagged_float64 buf x =
  write_untagged_int64 buf (Int64.bits_of_float x)

let write_untagged_string buf s =
  Bi_vint.write_uvint buf (String.length s);
  Bi_buf.add_string buf s

let write_untagged_int128 buf s =
  if String.length s <> 16 then
    invalid_arg "Bi_io.write_untagged_int128";
  Bi_buf.add_string buf s

let write_untagged_uvint = Bi_vint.write_uvint
let write_untagged_svint = Bi_vint.write_svint


let write_tagged_int8 buf x =
  write_tag buf int8_tag;
  write_untagged_int8 buf x

let write_tagged_int16 buf x =
  write_tag buf int16_tag;
  write_untagged_int16 buf x

let write_tagged_int32 buf x =
  write_tag buf int32_tag;
  write_untagged_int32 buf x

let write_tagged_int64 buf x =
  write_tag buf int64_tag;
  write_untagged_int64 buf x

let write_tagged_int128 buf x =
  write_tag buf int128_tag;
  write_untagged_string buf x

let write_tagged_float64 buf x =
  write_tag buf float64_tag;
  write_untagged_float64 buf x

let write_tagged_string buf x =
  write_tag buf string_tag;
  write_untagged_string buf x

let write_tagged_uvint buf x =
  write_tag buf uvint_tag;
  write_untagged_uvint buf x

let write_tagged_svint buf x =
  write_tag buf svint_tag;
  write_untagged_svint buf x




let rec write_tree buf tagged (x : tree) =
  match x with
      `Int8 x ->
	if tagged then 
	  write_tag buf int8_tag;
	write_untagged_int8 buf x

    | `Int16 x ->
	if tagged then
	  write_tag buf int16_tag;
	write_untagged_int16 buf x

    | `Int32 x ->
	if tagged then
	  write_tag buf int32_tag;
	write_untagged_int32 buf x

    | `Int64 x ->
	if tagged then
	  write_tag buf int64_tag;
	write_untagged_int64 buf x

    | `Int128 x ->
	if tagged then
	  write_tag buf int128_tag;
	write_untagged_int128 buf x

    | `Float64 x ->
	if tagged then
	  write_tag buf float64_tag;
	write_untagged_float64 buf x

    | `Uvint x ->
	if tagged then
	  write_tag buf uvint_tag;
	Bi_vint.write_uvint buf x

    | `Svint x ->
	if tagged then
	  write_tag buf svint_tag;
	Bi_vint.write_svint buf x

    | `String s ->
	if tagged then
	  write_tag buf string_tag;
	write_untagged_string buf s

    | `Array (node_tag, a) ->
	if tagged then
	  write_tag buf array_tag;
	Bi_vint.write_uvint buf (Array.length a);
	write_tag buf node_tag;
	Array.iter (write_tree buf false) a
	
    | `Tuple a ->
	if tagged then
	  write_tag buf tuple_tag;
	Bi_vint.write_uvint buf (Array.length a);
	Array.iter (write_tree buf true) a

    | `Record a ->
	if tagged then
	  write_tag buf record_tag;
	Bi_vint.write_uvint buf (Array.length a);
	Array.iter (write_field buf) a

    | `Num_variant (i, x) ->
	if tagged then
	  write_tag buf num_variant_tag;
	write_numtag buf i (x <> None);
	(match x with
	     None -> ()
	   | Some v -> write_tree buf true v)

    | `Variant (s, h, x) ->
	if tagged then
	  write_tag buf variant_tag;
	write_hashtag buf h (x <> None);
	(match x with
	     None -> ()
	   | Some v -> write_tree buf true v)

    | `Tuple_table (node_tags, a) ->
	if tagged then
	  write_tag buf tuple_table_tag;
	let row_num = Array.length a in
	Bi_vint.write_uvint buf row_num;
	let col_num = Array.length node_tags in
	Bi_vint.write_uvint buf col_num;
	Array.iter (write_tag buf) node_tags;
	if row_num > 0 then (
	  for i = 0 to row_num - 1 do
	    let ai = a.(i) in
	    if Array.length ai <> col_num then
	      invalid_arg "Bi_io.write_tree: Malformed `Tuple_table";
	    for j = 0 to col_num - 1 do
	      write_tree buf false ai.(j)
	    done
	  done
	)

    | `Record_table (fields, a) ->
	if tagged then
	  write_tag buf record_table_tag;
	let row_num = Array.length a in
	Bi_vint.write_uvint buf row_num;
	let col_num = Array.length fields in
	Bi_vint.write_uvint buf col_num;
	Array.iter (
	  fun (name, h, tag) ->
	    write_hashtag buf h true;
	    write_tag buf tag
	) fields;
	if row_num > 0 then (
	  for i = 0 to row_num - 1 do
	    let ai = a.(i) in
	    if Array.length ai <> col_num then
	      invalid_arg "Bi_io.write_tree: Malformed `Record_table";
	    for j = 0 to col_num - 1 do
	      write_tree buf false ai.(j)
	    done
	  done
	)

    | `Matrix (node_tag, col_num, a) ->
	if tagged then
	  write_tag buf matrix_tag;
	let row_num = Array.length a in
	Bi_vint.write_uvint buf row_num;
	Bi_vint.write_uvint buf col_num;
	write_tag buf node_tag;
	if row_num > 0 then (
	  for i = 0 to row_num - 1 do
	    let ai = a.(i) in
	    if Array.length ai <> col_num then
	      invalid_arg "Bi_io.write_tree: Malformed `Matrix";
	    for j = 0 to col_num - 1 do
	      write_tree buf false ai.(j)
	    done
	  done
	)


and write_field buf (s, h, x) =
  write_hashtag buf h true;
  write_tree buf true x

let string_of_tree x =
  let buf = Bi_buf.create 1000 in
  write_tree buf true x;
  Bi_buf.contents buf

let read_tag s pos =
  if !pos >= String.length s then
    Bi_util.error "Corrupted data (tag)";
  let x = Char.code s.[!pos] in
  incr pos;
  x

let read_untagged_int8 s pos =
  if !pos >= String.length s then
    Bi_util.error "Corrupted data (int8)";
  let x = Char.code s.[!pos] in
  incr pos;
  x

let read_untagged_int16 s pos =
  let i = !pos in
  if i + 2 > String.length s then
    Bi_util.error "Corrupted data (int16)";
  let x = ((Char.code s.[i]) lsl 8) lor (Char.code s.[i+1]) in
  pos := !pos + 2;
  x

let read_untagged_int32 s pos =
  let i = !pos in
  if i + 4 > String.length s then
    Bi_util.error "Corrupted data (int32)";
  let x1 =
    Int32.of_int (((Char.code s.[i  ]) lsl 8) lor (Char.code s.[i+1])) in
  let x2 =
    Int32.of_int (((Char.code s.[i+2]) lsl 8) lor (Char.code s.[i+3])) in
  pos := !pos + 4;
  Int32.logor (Int32.shift_left x1 16) x2

let read_untagged_int64 s pos =
  let i = !pos in
  if i + 8 > String.length s then
    Bi_util.error "Corrupted data (int64)";
  let x1 =
    Int64.of_int (((Char.code s.[i  ]) lsl 8) lor (Char.code s.[i+1])) in
  let x2 =
    Int64.of_int (((Char.code s.[i+2]) lsl 8) lor (Char.code s.[i+3])) in
  let x3 =
    Int64.of_int (((Char.code s.[i+4]) lsl 8) lor (Char.code s.[i+5])) in
  let x4 =
    Int64.of_int (((Char.code s.[i+6]) lsl 8) lor (Char.code s.[i+7])) in
  pos := !pos + 8;
  Int64.logor (Int64.shift_left x1 48)
    (Int64.logor (Int64.shift_left x2 32)
       (Int64.logor (Int64.shift_left x3 24) x4))
  
let read_untagged_float64 s pos =
  Int64.float_of_bits (read_untagged_int64 s pos)

let read_untagged_string s pos =
  let len = Bi_vint.read_uvint s pos in
  if !pos + len > String.length s then
    Bi_util.error "Corrupted data (string)";
  let str = String.sub s !pos len in
  pos := !pos + len;
  str

let read_untagged_int128 s pos =
  if !pos + 16 > String.length s then
    Bi_util.error "Corrupted data (int128)";
  let str = String.sub s !pos 16 in
  pos := !pos + 16;
  str

let read_untagged_uvint = Bi_vint.read_uvint
let read_untagged_svint = Bi_vint.read_svint

let read_int8 s pos = `Int8 (read_untagged_int8 s pos)

let read_int16 s pos = `Int16 (read_untagged_int16 s pos)

let read_int32 s pos = `Int32 (read_untagged_int32 s pos)

let read_int64 s pos = `Int64 (read_untagged_int64 s pos)

let read_int128 s pos = `Int128 (read_untagged_int128 s pos)

let read_float s pos =
  `Float64 (read_untagged_float64 s pos)

let read_uvint s pos = `Uvint (read_untagged_uvint s pos)
let read_svint s pos = `Svint (read_untagged_svint s pos)

let read_string s pos = `String (read_untagged_string s pos)

let print s = print_string s; print_newline ()

let tree_of_string ?(unhash = make_unhash [])  s : tree =

  let rec read_array s pos =
    let len = Bi_vint.read_uvint s pos in
    let tag = read_tag s pos in
    let read = reader_of_tag tag in
    `Array (tag, Array.init len (fun _ -> read s pos))
      
  and read_tuple s pos =
    let len = Bi_vint.read_uvint s pos in
    `Tuple (Array.init len (fun _ -> read_tree s pos))
      
  and read_field s pos =
    let h = read_field_hashtag s pos in
    let name = unhash h in
    let x = read_tree s pos in
    (name, h, x)
      
  and read_record s pos =
    let len = Bi_vint.read_uvint s pos in
    `Record (Array.init len (fun _ -> read_field s pos))
    
  and read_num_variant_cont s pos i has_arg =
    let x =
      if has_arg then
	Some (read_tree s pos)
      else
	None
    in
    `Num_variant (i, x)
  
  and read_num_variant s pos =
    read_numtag s pos read_num_variant_cont
      
  and read_variant_cont s pos h has_arg =
    let name = unhash h in
    let x =
      if has_arg then
	Some (read_tree s pos)
      else
	None
    in
    `Variant (name, h, x)
  
  and read_variant s pos =
    read_hashtag s pos read_variant_cont
      
  and read_tuple_table s pos =
    let row_num = Bi_vint.read_uvint s pos in
    let col_num = Bi_vint.read_uvint s pos in
    let tags = Array.init col_num (fun _ -> read_tag s pos) in
    let readers = Array.map reader_of_tag tags in
    let a =
      Array.init row_num
	(fun _ ->
	   Array.init col_num (fun j -> readers.(j) s pos))
    in
    `Tuple_table (tags, a)

  and read_record_table s pos =
    let row_num = Bi_vint.read_uvint s pos in
    let col_num = Bi_vint.read_uvint s pos in
    let fields = 
      Array.init col_num (
	fun _ ->
	  let h = read_field_hashtag s pos in
	  let name = unhash h in
	  let tag = read_tag s pos in
	  (name, h, tag)
      )
    in
    let readers = 
      Array.map (fun (name, h, tag) -> reader_of_tag tag) fields in
    let a =
      Array.init row_num
	(fun _ ->
	   Array.init col_num (fun j -> readers.(j) s pos))
    in
    `Record_table (fields, a)

  and read_matrix s pos =
    let row_num = Bi_vint.read_uvint s pos in
    let col_num = Bi_vint.read_uvint s pos in
    let tag = read_tag s pos in
    let reader = reader_of_tag tag in
    let read i = reader s pos in
    let a = Array.init row_num (fun _ -> Array.init col_num read) in
    `Matrix (tag, col_num, a)
      

  and reader_of_tag = function
      1 (* int8 *) -> read_int8
    | 2 (* int16 *) -> read_int16
    | 3 (* int32 *) -> read_int32
    | 4 (* int64 *) -> read_int64
    | 5 (* int128 *) -> read_int128
    | 12 (* float *) -> read_float
    | 16 (* uvint *) -> read_uvint
    | 17 (* svint *) -> read_svint
    | 18 (* string *) -> read_string
    | 19 (* array *) -> read_array
    | 20 (* tuple *) -> read_tuple
    | 21 (* record *) -> read_record
    | 22 (* num_variant *) -> read_num_variant
    | 23 (* variant *) -> read_variant
    | 24 (* tuple_table *) -> read_tuple_table
    | 25 (* record_table *) -> read_record_table
    | 26 (* matrix *) -> read_matrix
    | _ -> Bi_util.error "Corrupted data (invalid tag)"
	
  and read_tree s pos : tree =
    reader_of_tag (read_tag s pos) s pos
      
  in
  read_tree s (ref 0)


module Pp =
struct
  open Easy_format

  let array = list
  let record = list
  let tuple = { list with
		  space_after_opening = false;
		  space_before_closing = false;
		  align_closing = false }
  let variant = { list with
		    separators_stick_left = true }
		    
  let map f a = Array.to_list (Array.map f a)

  let rec format (x : tree) =
    match x with
	`Int8 x -> Atom (sprintf "0x%02x" x, atom)
      | `Int16 x -> Atom (sprintf "0x%04x" x, atom)
      | `Int32 x -> Atom (sprintf "0x%08lx" x, atom)
      | `Int64 x -> Atom (sprintf "0x%016Lx" x, atom)
      | `Int128 x -> Atom ("0x" ^ Digest.to_hex x, atom)
      | `Float64 x -> Atom (string_of_float x, atom)
      | `Uvint x -> Atom (string_of_int x, atom)
      | `Svint x -> Atom (string_of_int x, atom)
      | `String s -> Atom (sprintf "%S" s, atom)
      | `Array (_, a) -> List (("[", ";", "]", array), map format a)
      | `Tuple a -> List (("(", ",", ")", tuple), map format a)
      | `Record a -> List (("{", ";", "}", record), map format_field a)
      | `Num_variant (i, o) ->
	  let cons = Atom (sprintf "`%i" i, atom) in
	  (match o with
	       None -> cons
	     | Some x -> Label ((cons, label), format x))
      | `Variant (s, _, o) ->
	  let cons = Atom (sprintf "`%s" s, atom) in
	  (match o with
	       None -> cons
	     | Some x -> Label ((cons, label), format x))
	  
      | `Tuple_table (_, aa) -> 
	  let tuple_array =
	    `Array (tuple_tag, Array.map (fun a -> `Tuple a) aa) in
	  format tuple_array
	    
      | `Record_table (header, aa) ->
	  let record_array =
	    `Array (
	      record_tag,
	      Array.map (
		fun a ->
		  `Record (
		    Array.mapi (
		      fun i x -> 
			let s, h, _ = header.(i) in
			(s, h, x)
		    ) a
		  )
	      ) aa
	    ) in
	  format record_array
	    
      | `Matrix (cell_tag, _, aa) ->
	  let array_array =
	    `Array (
	      array_tag,
	      Array.map (fun a -> `Array (cell_tag, a)) aa
	    ) in
	  format array_array
	    
  and format_field (s, h, x) =
    Label ((Atom (sprintf "%s =" s, atom), label), format x)
end


let inspect ?unhash s =
  Easy_format.Pretty.to_string (Pp.format (tree_of_string ?unhash s))
