(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2018.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

type error += Unknown_primitive_name of string (* `Permanent *)
type error += Invalid_case of string (* `Permanent *)
type error += Invalid_primitive_name of string Micheline.canonical * Micheline.canonical_location (* `Permanent *)

type prim =
  | K_parameter
  | K_storage
  | K_code
  | D_False
  | D_Elt
  | D_Left
  | D_None
  | D_Pair
  | D_Right
  | D_Some
  | D_True
  | D_Unit
  | I_PACK
  | I_UNPACK
  | I_BLAKE2B
  | I_SHA256
  | I_SHA512
  | I_ABS
  | I_ADD
  | I_AMOUNT
  | I_AND
  | I_BALANCE
  | I_CAR
  | I_CDR
  | I_CHECK_SIGNATURE
  | I_COMPARE
  | I_CONCAT
  | I_CONS
  | I_CREATE_ACCOUNT
  | I_CREATE_CONTRACT
  | I_IMPLICIT_ACCOUNT
  | I_DIP
  | I_DROP
  | I_DUP
  | I_EDIV
  | I_EMPTY_MAP
  | I_EMPTY_SET
  | I_EQ
  | I_EXEC
  | I_FAILWITH
  | I_GE
  | I_GET
  | I_GT
  | I_HASH_KEY
  | I_IF
  | I_IF_CONS
  | I_IF_LEFT
  | I_IF_NONE
  | I_INT
  | I_LAMBDA
  | I_LE
  | I_LEFT
  | I_LOOP
  | I_LSL
  | I_LSR
  | I_LT
  | I_MAP
  | I_MEM
  | I_MUL
  | I_NEG
  | I_NEQ
  | I_NIL
  | I_NONE
  | I_NOT
  | I_NOW
  | I_OR
  | I_PAIR
  | I_PUSH
  | I_RIGHT
  | I_SIZE
  | I_SOME
  | I_SOURCE
  | I_SENDER
  | I_SELF
  | I_STEPS_TO_QUOTA
  | I_SUB
  | I_SWAP
  | I_TRANSFER_TOKENS
  | I_SET_DELEGATE
  | I_UNIT
  | I_UPDATE
  | I_XOR
  | I_ITER
  | I_LOOP_LEFT
  | I_ADDRESS
  | I_CONTRACT
  | I_ISNAT
  | I_CAST
  | I_RENAME
  | T_bool
  | T_contract
  | T_int
  | T_key
  | T_key_hash
  | T_lambda
  | T_list
  | T_map
  | T_big_map
  | T_nat
  | T_option
  | T_or
  | T_pair
  | T_set
  | T_signature
  | T_string
  | T_bytes
  | T_mutez
  | T_timestamp
  | T_unit
  | T_operation
  | T_address

val prim_encoding : prim Data_encoding.encoding

val string_of_prim : prim -> string

val prim_of_string : string -> prim tzresult

val prims_of_strings : string Micheline.canonical -> prim Micheline.canonical tzresult

val strings_of_prims : prim Micheline.canonical -> string Micheline.canonical
