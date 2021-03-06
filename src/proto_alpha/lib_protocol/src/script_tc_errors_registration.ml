(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2017.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

open Alpha_context
open Micheline
open Script
open Script_typed_ir
open Script_tc_errors
open Script_ir_translator

(* Helpers for encoding *)
let type_map_enc =
  let open Data_encoding in
  let stack_enc = list (tup2 Script.expr_encoding (list string)) in
  list
    (conv
       (fun (loc, (bef, aft)) -> (loc, bef, aft))
       (fun (loc, bef, aft) -> (loc, (bef, aft)))
       (obj3
          (req "location" Script.location_encoding)
          (req "stackBefore" stack_enc)
          (req "stackAfter" stack_enc)))

let rec strip_var_annots = function
  | Int _ | String _ | Bytes _ as atom -> atom
  | Seq (loc, args) -> Seq (loc, List.map strip_var_annots args)
  | Prim (loc, name, args, annots) ->
      let not_var_annot s = Compare.Char.(String.get s 0 <> '@') in
      let annots = List.filter not_var_annot annots in
      Prim (loc, name, List.map strip_var_annots args, annots)

let ex_ty_enc =
  Data_encoding.conv
    (fun (Ex_ty ty) ->
       strip_locations (strip_var_annots (unparse_ty ty)))
    (fun expr ->
       match parse_ty ~allow_big_map:true ~allow_operation:true (root expr) with
       | Ok ty -> ty
       | _ -> assert false)
    Script.expr_encoding

let var_annot_enc =
  let open Data_encoding in
  conv
    (function `Var_annot x -> "@" ^ x)
    (function x ->
       assert (Compare.Int.(String.length x > 0) && Compare.Char.(String.get x 0 = '@')) ;
       `Var_annot (String.sub x 1 (String.length x - 1)))
    string

let ex_stack_ty_enc =
  let open Data_encoding in
  let rec unfold = function
    | Ex_stack_ty (Item_t (ty, rest, annot)) ->
        (Ex_ty ty, annot) :: unfold (Ex_stack_ty rest)
    | Ex_stack_ty Empty_t -> [] in
  let rec fold = function
    | (Ex_ty ty, annot) :: rest ->
        let Ex_stack_ty rest = fold rest in
        Ex_stack_ty (Item_t (ty, rest, annot))
    | [] -> Ex_stack_ty Empty_t in
  conv unfold fold
    (list
       (obj2
          (req "type" ex_ty_enc)
          (opt "annot" var_annot_enc)))

(* main registration *)
let () =
  let open Data_encoding in
  let located enc =
    merge_objs
      (obj1 (req "location" Script.location_encoding))
      enc in
  let arity_enc =
    int8 in
  let namespace_enc =
    def "primitiveNamespace"
      ~title: "Primitive namespace"
      ~description:
        "One of the three possible namespaces of primitive \
         (data constructor, type name or instruction)." @@
    string_enum [ "type", Type_namespace ;
                  "constant", Constant_namespace ;
                  "instruction", Instr_namespace ] in
  let kind_enc =
    def "expressionKind"
      ~title: "Expression kind"
      ~description:
        "One of the four possible kinds of expression \
         (integer, string, primitive application or sequence)." @@
    string_enum [ "integer", Int_kind ;
                  "string", String_kind ;
                  "bytes", Bytes_kind ;
                  "primitiveApplication", Prim_kind ;
                  "sequence", Seq_kind ] in
  (* -- Structure errors ---------------------- *)
  (* Invalid arity *)
  register_error_kind
    `Permanent
    ~id:"invalidArityTypeError"
    ~title: "Invalid arity (typechecking error)"
    ~description:
      "In a script or data expression, a primitive was applied \
       to an unsupported number of arguments."
    (located (obj3
                (req "primitiveName" Script.prim_encoding)
                (req "expectedArity" arity_enc)
                (req "wrongArity" arity_enc)))
    (function
      | Invalid_arity (loc, name, exp, got) ->
          Some (loc, (name, exp, got))
      | _ -> None)
    (fun (loc, (name, exp, got)) ->
       Invalid_arity (loc, name, exp, got)) ;
  (* Missing field *)
  register_error_kind
    `Permanent
    ~id:"missingScriptField"
    ~title:"Script is missing a field (parse error)"
    ~description:
      "When parsing script, a field was expected, but not provided"
    (obj1 (req "prim" prim_encoding))
    (function Missing_field prim -> Some prim | _ -> None)
    (fun prim -> Missing_field prim) ;
  (* Invalid primitive *)
  register_error_kind
    `Permanent
    ~id:"invalidPrimitiveTypeError"
    ~title: "Invalid primitive (typechecking error)"
    ~description:
      "In a script or data expression, a primitive was unknown."
    (located (obj2
                (dft "expectedPrimitiveNames" (list prim_encoding) [])
                (req "wrongPrimitiveName" prim_encoding)))
    (function
      | Invalid_primitive (loc, exp, got) -> Some (loc, (exp, got))
      | _ -> None)
    (fun (loc, (exp, got)) ->
       Invalid_primitive (loc, exp, got)) ;
  (* Invalid kind *)
  register_error_kind
    `Permanent
    ~id:"invalidExpressionKindTypeError"
    ~title: "Invalid expression kind (typechecking error)"
    ~description:
      "In a script or data expression, an expression was of the wrong kind \
       (for instance a string where only a primitive applications can appear)."
    (located (obj2
                (req "expectedKinds" (list kind_enc))
                (req "wrongKind" kind_enc)))
    (function
      | Invalid_kind (loc, exp, got) -> Some (loc, (exp, got))
      | _ -> None)
    (fun (loc, (exp, got)) ->
       Invalid_kind (loc, exp, got)) ;
  (* Invalid namespace *)
  register_error_kind
    `Permanent
    ~id:"invalidPrimitiveNamespaceTypeError"
    ~title: "Invalid primitive namespace (typechecking error)"
    ~description:
      "In a script or data expression, a primitive was of the wrong namespace."
    (located (obj3
                (req "primitiveName" prim_encoding)
                (req "expectedNamespace" namespace_enc)
                (req "wrongNamespace" namespace_enc)))
    (function
      | Invalid_namespace (loc, name, exp, got) -> Some (loc, (name, exp, got))
      | _ -> None)
    (fun (loc, (name, exp, got)) ->
       Invalid_namespace (loc, name, exp, got)) ;
  (* Duplicate field *)
  register_error_kind
    `Permanent
    ~id:"duplicateScriptField"
    ~title: "Script has a duplicated field (parse error)"
    ~description:
      "When parsing script, a field was found more than once"
    (obj2
       (req "loc" location_encoding)
       (req "prim" prim_encoding))
    (function Duplicate_field (loc, prim) -> Some (loc, prim) | _ -> None)
    (fun (loc, prim) -> Duplicate_field (loc, prim)) ;
  (* Unexpected big_map *)
  register_error_kind
    `Permanent
    ~id:"unexpectedBigMap"
    ~title: "Big map in unauthorized position (type error)"
    ~description:
      "When parsing script, a big_map type was found somewhere else \
       than in the left component of the toplevel storage pair."
    (obj1
       (req "loc" location_encoding))
    (function Unexpected_big_map loc -> Some loc | _ -> None)
    (fun loc -> Unexpected_big_map loc) ;
  (* Unexpected operation *)
  register_error_kind
    `Permanent
    ~id:"unexpectedOperation"
    ~title: "Big map in unauthorized position (type error)"
    ~description:
      "When parsing script, a operation type was found \
       in the storage or parameter field."
    (obj1
       (req "loc" location_encoding))
    (function Unexpected_operation loc -> Some loc | _ -> None)
    (fun loc -> Unexpected_operation loc) ;
  (* -- Value typing errors ---------------------- *)
  (* Unordered map keys *)
  register_error_kind
    `Permanent
    ~id:"unorderedMapLiteral"
    ~title:"Invalid map key order"
    ~description:"Map keys must be in strictly increasing order"
    (obj2
       (req "location" Script.location_encoding)
       (req "item" Script.expr_encoding))
    (function
      | Unordered_map_keys (loc, expr) -> Some (loc, expr)
      | _ -> None)
    (fun (loc, expr) -> Unordered_map_keys (loc, expr));
  (* Duplicate map keys *)
  register_error_kind
    `Permanent
    ~id:"duplicateMapKeys"
    ~title:"Duplicate map keys"
    ~description:"Map literals cannot contain duplicated keys"
    (obj2
       (req "location" Script.location_encoding)
       (req "item" Script.expr_encoding))
    (function
      | Duplicate_map_keys (loc, expr) -> Some (loc, expr)
      | _ -> None)
    (fun (loc, expr) -> Duplicate_map_keys (loc, expr));
  (* Unordered set values *)
  register_error_kind
    `Permanent
    ~id:"unorderedSetLiteral"
    ~title:"Invalid set value order"
    ~description:"Set values must be in strictly increasing order"
    (obj2
       (req "location" Script.location_encoding)
       (req "value" Script.expr_encoding))
    (function
      | Unordered_set_values (loc, expr) -> Some (loc, expr)
      | _ -> None)
    (fun (loc, expr) -> Unordered_set_values (loc, expr));
  (* Duplicate set values *)
  register_error_kind
    `Permanent
    ~id:"duplicateSetValuesInLiteral"
    ~title:"Sets literals cannot contain duplicate elements"
    ~description:"Set literals cannot contain duplicate elements, \
                  but a duplicae was found while parsing."
    (obj2
       (req "location" Script.location_encoding)
       (req "value" Script.expr_encoding))
    (function
      | Duplicate_set_values (loc, expr) -> Some (loc, expr)
      | _ -> None)
    (fun (loc, expr) -> Duplicate_set_values (loc, expr));
  (* -- Instruction typing errors ------------- *)
  (* Fail not in tail position *)
  register_error_kind
    `Permanent
    ~id:"failNotInTailPositionTypeError"
    ~title: "FAIL not in tail position (typechecking error)"
    ~description:
      "There is non trivial garbage code after a FAIL instruction."
    (located empty)
    (function
      | Fail_not_in_tail_position loc -> Some (loc, ())
      | _ -> None)
    (fun (loc, ()) ->
       Fail_not_in_tail_position loc) ;
  (* Undefined binary operation *)
  register_error_kind
    `Permanent
    ~id:"undefinedBinopTypeError"
    ~title: "Undefined binop (typechecking error)"
    ~description:
      "A binary operation is called on operands of types \
       over which it is not defined."
    (located (obj3
                (req "operatorName" prim_encoding)
                (req "wrongLeftOperandType" ex_ty_enc)
                (req "wrongRightOperandType" ex_ty_enc)))
    (function
      | Undefined_binop (loc, n, tyl, tyr) ->
          Some (loc, (n, Ex_ty tyl, Ex_ty tyr))
      | _ -> None)
    (fun (loc, (n, Ex_ty tyl, Ex_ty tyr)) ->
       Undefined_binop (loc, n, tyl, tyr)) ;
  (* Undefined unary operation *)
  register_error_kind
    `Permanent
    ~id:"undefinedUnopTypeError"
    ~title: "Undefined unop (typechecking error)"
    ~description:
      "A unary operation is called on an operand of type \
       over which it is not defined."
    (located (obj2
                (req "operatorName" prim_encoding)
                (req "wrongOperandType" ex_ty_enc)))
    (function
      | Undefined_unop (loc, n, ty) ->
          Some (loc, (n, Ex_ty ty))
      | _ -> None)
    (fun (loc, (n, Ex_ty ty)) ->
       Undefined_unop (loc, n, ty)) ;
  (* Bad return *)
  register_error_kind
    `Permanent
    ~id:"badReturnTypeError"
    ~title: "Bad return (typechecking error)"
    ~description:
      "Unexpected stack at the end of a lambda or script."
    (located (obj2
                (req "expectedReturnType" ex_ty_enc)
                (req "wrongStackType" ex_stack_ty_enc)))
    (function
      | Bad_return (loc, sty, ty) -> Some (loc, (Ex_ty ty, Ex_stack_ty sty))
      | _ -> None)
    (fun (loc, (Ex_ty ty, Ex_stack_ty sty)) ->
       Bad_return (loc, sty, ty)) ;
  (* Bad stack *)
  register_error_kind
    `Permanent
    ~id:"badStackTypeError"
    ~title: "Bad stack (typechecking error)"
    ~description:
      "The stack has an unexpected length or contents."
    (located (obj3
                (req "primitiveName" prim_encoding)
                (req "relevantStackPortion" int16)
                (req "wrongStackType" ex_stack_ty_enc)))
    (function
      | Bad_stack (loc, name, s, sty) -> Some (loc, (name, s, Ex_stack_ty sty))
      | _ -> None)
    (fun (loc, (name, s, Ex_stack_ty sty)) ->
       Bad_stack (loc, name, s, sty)) ;
  (* Inconsistent annotations *)
  register_error_kind
    `Permanent
    ~id:"inconsistentAnnotations"
    ~title:"Annotations inconsistent between branches"
    ~description:"The annotations on two types could not be merged"
    (obj2
       (req "annot1" string)
       (req "annot2" string))
    (function Inconsistent_annotations (annot1, annot2) -> Some (annot1, annot2)
            | _ -> None)
    (fun (annot1, annot2) -> Inconsistent_annotations (annot1, annot2)) ;
  (* Inconsistent field annotations *)
  register_error_kind
    `Permanent
    ~id:"inconsistentFieldAnnotations"
    ~title:"Annotations for field accesses is inconsistent"
    ~description:"The specified field does not match the field annotation in the type"
    (obj2
       (req "annot1" string)
       (req "annot2" string))
    (function Inconsistent_field_annotations (annot1, annot2) -> Some (annot1, annot2)
            | _ -> None)
    (fun (annot1, annot2) -> Inconsistent_field_annotations (annot1, annot2)) ;
  (* Inconsistent type annotations *)
  register_error_kind
    `Permanent
    ~id:"inconsistentTypeAnnotations"
    ~title:"Types contain inconsistent annotations"
    ~description:"The two types contain annotations that do not match"
    (located (obj2
                (req "type1" ex_ty_enc)
                (req "type2" ex_ty_enc)))
    (function
      | Inconsistent_type_annotations (loc, ty1, ty2) -> Some (loc, (Ex_ty ty1, Ex_ty ty2))
      | _ -> None)
    (fun (loc, (Ex_ty ty1, Ex_ty ty2)) -> Inconsistent_type_annotations (loc, ty1, ty2)) ;
  (* Unexpected annotation *)
  register_error_kind
    `Permanent
    ~id:"unexpectedAnnotation"
    ~title:"An annotation was encountered where no annotation is expected"
    ~description:"A node in the syntax tree was impropperly annotated"
    (located empty)
    (function Unexpected_annotation loc -> Some (loc, ())
            | _ -> None)
    (fun (loc, ()) -> Unexpected_annotation loc);
  (* Unexpected annotation *)
  register_error_kind
    `Permanent
    ~id:"ungroupedAnnotations"
    ~title:"Annotations of the same kind were found spread apart"
    ~description:"Annotations of the same kind must be grouped"
    (located empty)
    (function Ungrouped_annotations loc -> Some (loc, ())
            | _ -> None)
    (fun (loc, ()) -> Ungrouped_annotations loc);
  (* Unmatched branches *)
  register_error_kind
    `Permanent
    ~id:"unmatchedBranchesTypeError"
    ~title: "Unmatched branches (typechecking error)"
    ~description:
      "At the join point at the end of two code branches \
       the stacks have inconsistent lengths or contents."
    (located (obj2
                (req "firstStackType" ex_stack_ty_enc)
                (req "otherStackType" ex_stack_ty_enc)))
    (function
      | Unmatched_branches (loc, stya, styb) ->
          Some (loc, (Ex_stack_ty stya, Ex_stack_ty styb))
      | _ -> None)
    (fun (loc, (Ex_stack_ty stya, Ex_stack_ty styb)) ->
       Unmatched_branches (loc, stya, styb)) ;
  (* Bad stack item *)
  register_error_kind
    `Permanent
    ~id:"badStackItemTypeError"
    ~title: "Bad stack item (typechecking error)"
    ~description:
      "The type of a stack item is unexpected \
       (this error is always accompanied by a more precise one)."
    (obj1 (req "itemLevel" int16))
    (function
      | Bad_stack_item n -> Some n
      | _ -> None)
    (fun n ->
       Bad_stack_item n) ;
  (* SELF in lambda *)
  register_error_kind
    `Permanent
    ~id:"selfInLambda"
    ~title: "SELF instruction in lambda (typechecking error)"
    ~description:
      "A SELF instruction was encountered in a lambda expression."
    (located empty)
    (function
      | Self_in_lambda loc -> Some (loc, ())
      | _ -> None)
    (fun (loc, ()) ->
       Self_in_lambda loc) ;
  (* Bad stack length *)
  register_error_kind
    `Permanent
    ~id:"inconsistentStackLengthsTypeError"
    ~title: "Inconsistent stack lengths (typechecking error)"
    ~description:
      "A stack was of an unexpected length \
       (this error is always in the context of a located error)."
    empty
    (function
      | Bad_stack_length -> Some ()
      | _ -> None)
    (fun () ->
       Bad_stack_length) ;
  (* -- Value typing errors ------------------- *)
  (* Invalid constant *)
  register_error_kind
    `Permanent
    ~id:"invalidConstantTypeError"
    ~title: "Invalid constant (typechecking error)"
    ~description:
      "A data expression was invalid for its expected type."
    (located (obj2
                (req "expectedType" ex_ty_enc)
                (req "wrongExpression" Script.expr_encoding)))
    (function
      | Invalid_constant (loc, expr, ty) ->
          Some (loc, (Ex_ty ty, expr))
      | _ -> None)
    (fun (loc, (Ex_ty ty, expr)) ->
       Invalid_constant (loc, expr, ty)) ;
  (* Invalid contract *)
  register_error_kind
    `Permanent
    ~id:"invalidContractTypeError"
    ~title: "Invalid contract (typechecking error)"
    ~description:
      "A script or data expression references a contract that does not \
       exist or assumes a wrong type for an existing contract."
    (located (obj1 (req "contract" Contract.encoding)))
    (function
      | Invalid_contract (loc, c) ->
          Some (loc, c)
      | _ -> None)
    (fun (loc, c) ->
       Invalid_contract (loc, c)) ;
  (* Comparable type expected *)
  register_error_kind
    `Permanent
    ~id:"comparableTypeExpectedTypeError"
    ~title: "Comparable type expected (typechecking error)"
    ~description:
      "A non comparable type was used in a place where \
       only comparable types are accepted."
    (located (obj1 (req "wrongType" ex_ty_enc)))
    (function
      | Comparable_type_expected (loc, ty) -> Some (loc, Ex_ty ty)
      | _ -> None)
    (fun (loc, Ex_ty ty) ->
       Comparable_type_expected (loc, ty)) ;
  (* Inconsistent types *)
  register_error_kind
    `Permanent
    ~id:"InconsistentTypesTypeError"
    ~title: "Inconsistent types (typechecking error)"
    ~description:
      "This is the basic type clash error, \
       that appears in several places where the equality of \
       two types have to be proven, it is always accompanied \
       with another error that provides more context."
    (obj2
       (req "firstType" ex_ty_enc)
       (req "otherType" ex_ty_enc))
    (function
      | Inconsistent_types (tya, tyb) ->
          Some (Ex_ty tya, Ex_ty tyb)
      | _ -> None)
    (fun (Ex_ty tya, Ex_ty tyb) ->
       Inconsistent_types (tya, tyb)) ;
  (* -- Instruction typing errors ------------------- *)
  (* Invalid map body *)
  register_error_kind
    `Permanent
    ~id:"invalidMapBody"
    ~title: "Invalid map body"
    ~description:
      "The body of a map block did not match the expected type"
    (obj2
       (req "loc" Script.location_encoding)
       (req "bodyType" ex_stack_ty_enc))
    (function
      | Invalid_map_body (loc, stack) ->
          Some (loc, Ex_stack_ty stack)
      | _ -> None)
    (fun (loc, Ex_stack_ty stack) ->
       Invalid_map_body (loc, stack)) ;
  (* Invalid map block FAIL *)
  register_error_kind
    `Permanent
    ~id:"invalidMapBlockFail"
    ~title:"FAIL instruction occurred as body of map block"
    ~description:"FAIL cannot be the only instruction in the body. \
                  The propper type of the return list cannot be inferred."
    (obj1 (req "loc" Script.location_encoding))
    (function
      | Invalid_map_block_fail loc -> Some loc
      | _ -> None)
    (fun loc -> Invalid_map_block_fail loc) ;
  (* Invalid ITER body *)
  register_error_kind
    `Permanent
    ~id:"invalidIterBody"
    ~title:"ITER body returned wrong stack type"
    ~description:"The body of an ITER instruction \
                  must result in the same stack type as before \
                  the ITER."
    (obj3
       (req "loc" Script.location_encoding)
       (req "befStack" ex_stack_ty_enc)
       (req "aftStack" ex_stack_ty_enc))
    (function
      | Invalid_iter_body (loc, bef, aft) -> Some (loc, Ex_stack_ty bef, Ex_stack_ty aft)
      | _ -> None)
    (fun (loc, Ex_stack_ty bef, Ex_stack_ty aft) -> Invalid_iter_body (loc, bef, aft)) ;
  (* Type too large *)
  register_error_kind
    `Permanent
    ~id:"typeTooLarge"
    ~title:"Stack item type too large"
    ~description:"An instruction generated a type larger than the limit."
    (obj3
       (req "loc" Script.location_encoding)
       (req "typeSize" uint16)
       (req "maximumTypeSize" uint16))
    (function
      | Type_too_large (loc, ts, maxts) -> Some (loc, ts, maxts)
      | _ -> None)
    (fun (loc, ts, maxts) -> Type_too_large (loc, ts, maxts)) ;
  (* -- Toplevel errors ------------------- *)
  (* Ill typed data *)
  register_error_kind
    `Permanent
    ~id:"illTypedDataTypeError"
    ~title: "Ill typed data (typechecking error)"
    ~description:
      "The toplevel error thrown when trying to typecheck \
       a data expression against a given type \
       (always followed by more precise errors)."
    (obj3
       (opt "identifier" string)
       (req "expectedType" ex_ty_enc)
       (req "illTypedExpression" Script.expr_encoding))
    (function
      | Ill_typed_data (name, expr, ty) -> Some (name, Ex_ty ty,  expr)
      | _ -> None)
    (fun (name, Ex_ty ty,  expr) ->
       Ill_typed_data (name, expr, ty)) ;
  (* Ill formed type *)
  register_error_kind
    `Permanent
    ~id:"illFormedTypeTypeError"
    ~title: "Ill formed type (typechecking error)"
    ~description:
      "The toplevel error thrown when trying to parse a type expression \
       (always followed by more precise errors)."
    (obj3
       (opt "identifier" string)
       (req "illFormedExpression" Script.expr_encoding)
       (req "location" Script.location_encoding))
    (function
      | Ill_formed_type (name, expr, loc) -> Some (name, expr, loc)
      | _ -> None)
    (fun (name, expr, loc) ->
       Ill_formed_type (name, expr, loc)) ;
  (* Ill typed contract *)
  register_error_kind
    `Permanent
    ~id:"illTypedContractTypeError"
    ~title: "Ill typed contract (typechecking error)"
    ~description:
      "The toplevel error thrown when trying to typecheck \
       a contract code against given input, output and storage types \
       (always followed by more precise errors)."
    (obj2
       (req "illTypedCode" Script.expr_encoding)
       (req "typeMap" type_map_enc))
    (function
      | Ill_typed_contract (expr, type_map) ->
          Some (expr, type_map)
      | _ -> None)
    (fun (expr, type_map) ->
       Ill_typed_contract (expr, type_map))
