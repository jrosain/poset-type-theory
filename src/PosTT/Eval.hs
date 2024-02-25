-- | Evaluation of Terms into Semantic Values
module PosTT.Eval where

import Algebra.Lattice

import Data.Tuple.Extra (fst3)

import PosTT.Terms
import PosTT.Values
import PosTT.Poset


--------------------------------------------------------------------------------
---- Utilities 

-- | Looks up fibrant value in environment. If it is a definition, then it is
--   evaluated. Thus, the current stage is required.
lookupFib :: AtStage (Env -> Name -> Val)
lookupFib (EnvFib _ y v)       x | y == x = v
lookupFib rho@(EnvDef _ y t _) x | y == x = eval rho t -- recursive definition
lookupFib (ConsEnv rho)        x = rho `lookupFib` x

lookupInt :: Env -> Gen -> VI
lookupInt (EnvInt _ y r) x | y == x = r
lookupInt (ConsEnv rho)  x = rho `lookupInt` x

reAppDef :: AtStage (Name -> Env -> Val)
reAppDef d (EnvFib rho x v) 
  | x == d = VVar d
  | x /= d = reAppDef d rho `doApp` v


--------------------------------------------------------------------------------
---- Eval

class Eval a where
  type Sem a
  eval :: AtStage (Env -> a -> Sem a)

closedEval :: Eval a => a -> Sem a
closedEval = bindStage terminalStage $ eval EmptyEnv

instance Eval Tm where
  type Sem Tm = Val

  eval :: AtStage (Env -> Tm -> Val)
  eval rho = \case
    U            -> VU
    Var x        -> rho `lookupFib` x
    Let d t ty s -> extName d $ eval (EnvDef rho d t ty) s

    Pi a b  -> VPi (eval rho a) (eval rho b)
    Lam t   -> VLam (eval rho t)
    App s t -> eval rho s `doApp` eval rho t

    Sigma a b -> VSigma (eval rho a) (eval rho b)
    Pair s t  -> VPair (eval rho s) (eval rho t)
    Pr1 t     -> doPr1 (eval rho t)
    Pr2 t     -> doPr2 (eval rho t)

    Path a s t     -> VPath (eval rho a) (eval rho s) (eval rho t)
    PLam t t0 t1   -> VPLam (eval rho t) (eval rho t0) (eval rho t1)
    PApp t t0 t1 r -> doPApp (eval rho t) (eval rho t0) (eval rho t1) (eval rho r)

    Coe r0 r1 l         -> vCoePartial (eval rho r0) (eval rho r1) (eval rho l)
    HComp r0 r1 a u0 tb -> doHComp' (eval rho r0) (eval rho r1) (eval rho a) (eval rho u0) (eval rho tb)

    Ext a bs    -> vExt (eval rho a) (eval rho bs)
    ExtElm s ts -> vExtElm (eval rho s) (eval rho ts)
    ExtFun ws t -> doExtFun' (eval rho ws) (eval rho t)

    Sum d lbl  -> VSum (reAppDef d rho) (eval rho lbl)
    Con c args -> VCon c (eval rho args)
    Split f bs -> VSplitPartial (reAppDef f rho) (eval rho bs)

instance Eval I where
  type Sem I = VI

  eval :: AtStage (Env -> I -> VI)
  eval rho = \case
    Sup r s -> eval rho r \/ eval rho s
    Inf r s -> eval rho r /\ eval rho s
    I0      -> bot
    I1      -> top
    IVar i  -> rho `lookupInt` i

instance Eval Cof where
  type Sem Cof = VCof

  eval :: AtStage (Env -> Cof -> VCof)
  eval rho (Cof eqs) = VCof (map (eval rho) eqs)

instance Eval a => Eval (Sys a) where
  type Sem (Sys a) = Either (Sem a) (VSys (Sem a))

  eval :: AtStage (Env -> Sys a -> Either (Sem a) (VSys (Sem a)))
  eval rho (Sys bs) = simplifySys (VSys bs') 
    where bs' = [ (phi', extCof phi' (eval rho a)) | (phi, a) <- bs, let phi' = eval rho phi ]

instance Eval (Binder Tm) where
  type Sem (Binder Tm) = Closure Tm

  eval :: AtStage (Env -> Binder Tm -> Closure Tm)
  eval rho (Binder x t) = Closure x t rho

instance Eval (IntBinder Tm) where
  type Sem (IntBinder Tm) = IntClosure

  eval :: AtStage (Env -> IntBinder Tm -> IntClosure)
  eval rho (IntBinder i t) = IntClosure i t rho

instance Eval (TrIntBinder Tm) where
  type Sem (TrIntBinder Tm) = TrIntClosure

  -- | We evaluate a transparant binder, by evaluating the *open* term t under
  --   the binder. (TODO: How can i be already used if the terms have no shadowing?)
  eval :: AtStage (Env -> TrIntBinder Tm -> TrIntClosure)
  eval rho (TrIntBinder i t) = trIntCl i $ \i' -> eval (EnvInt rho i (iVar i')) t

instance Eval SplitBinder where
  type Sem SplitBinder = SplitClosure
  
  eval :: AtStage (Env -> SplitBinder -> SplitClosure)
  eval rho (SplitBinder xs t) = SplitClosure xs t rho

instance Eval Branch where
  type Sem Branch = VBranch

  eval :: AtStage (Env -> Branch -> VBranch)
  eval rho (Branch c t) = (c, eval rho t)

instance Eval Label where
  type Sem Label = VLabel

  eval :: AtStage (Env -> Label -> VLabel)
  eval rho (Label c tel) = (c, eval rho tel)

instance Eval Tel where
  type Sem Tel = VTel

  eval :: AtStage (Env -> Tel -> VTel)
  eval rho (Tel ts) = VTel ts rho

instance Eval a => Eval [a] where
  type Sem [a] = [Sem a]

  eval :: AtStage (Env -> [a] -> [Sem a])
  eval rho = map (eval rho)

instance (Eval a, Eval b) => Eval (a, b) where
  type Sem (a, b) = (Sem a, Sem b)

  eval :: AtStage (Env -> (a, b) -> (Sem a, Sem b))
  eval rho (a, b) = (eval rho a, eval rho b)

instance (Eval a, Eval b, Eval c) => Eval (a, b, c) where
  type Sem (a, b, c) = (Sem a, Sem b, Sem c)

  eval :: AtStage (Env -> (a, b, c) -> (Sem a, Sem b, Sem c))
  eval rho (a, b, c) = (eval rho a, eval rho b, eval rho c) 


--------------------------------------------------------------------------------
---- Closure Evaluation

class Apply c where
  type ArgType c
  type ResType c

  infixr 0 $$ 
  ($$) :: AtStage (c -> ArgType c -> ResType c)

instance Eval a => Apply (Closure a) where
  type ArgType (Closure a) = Val
  type ResType (Closure a) = Sem a

  ($$) :: AtStage (Closure a -> Val -> Sem a)
  Closure x t rho $$ v = eval (EnvFib rho x v) t

instance Apply IntClosure where
  type ArgType IntClosure = VI
  type ResType IntClosure = Val

  ($$) :: AtStage (IntClosure -> VI -> Val)
  IntClosure i t rho $$ r = eval (EnvInt rho i r) t

instance Apply TrIntClosure where
  type ArgType TrIntClosure = VI
  type ResType TrIntClosure = Val

  ($$) :: AtStage (TrIntClosure -> VI -> Val)
  TrIntClosure i v alpha $$ r = v @ Restr [(i, r)]

instance Apply SplitClosure where
  type ArgType SplitClosure = [Val]
  type ResType SplitClosure = Val

  ($$) :: AtStage (SplitClosure -> [Val] -> Val)
  SplitClosure xs t rho $$ vs = eval (rho `envFibs` (xs `zip` vs)) t 

-- | Forces the delayed restriction under the binder.
force :: AtStage (TrIntClosure -> TrIntClosure)
force cl@(TrIntClosure i _ _) = trIntCl i $ \j -> cl $$ iVar j


--------------------------------------------------------------------------------
---- Prelude Combinators

pId :: Val
pId = closedEval $ Lam $ Binder "A" $ Lam $ Binder "x" $ Var "x"



--------------------------------------------------------------------------------
---- Basic MLTT Combinators

doPr1 :: AtStage (Val -> Val)
doPr1 (VPair s _) = s
doPr1 (VNeu k)    = VPr1 k

doPr2 :: AtStage (Val -> Val)
doPr2 (VPair _ t) = t
doPr2 (VNeu k)    = VPr2 k

doApp :: AtStage (Val -> Val -> Val)
doApp (VLam cl)             v = cl $$ v
doApp (VNeu k)              v = VApp k v
doApp (VSplitPartial f bs)  v = doSplit f bs v
doApp (VCoePartial r0 r1 l) v = doCoe r0 r1 l v

doPApp :: AtStage (Val -> Val -> Val -> VI -> Val)
doPApp (VPLam cl _ _) _  _  r = cl $$ r
doPApp (VNeu k)       p0 p1 r
  | r === 0   = p0
  | r === 1   = p1
  | otherwise = VPApp k p0 p1 r

doSplit :: AtStage (Val -> [VBranch] -> Val -> Val)
doSplit f bs (VCon c as) | Just cl <- lookup c bs = cl $$ as
doSplit f bs (VNeu k)    = VSplit f bs k


--------------------------------------------------------------------------------
---- Extension Types

vExt :: AtStage (Val -> Either (VTy, Val, Val) (VSys (VTy, Val, Val)) -> Val)
vExt a = either fst3 (VExt a)

vExtElm :: AtStage (Val -> Either Val (VSys Val) -> Val)
vExtElm v = either id (VExtElm v) 

doExtFun' :: AtStage (Either Val (VSys Val) -> Val -> Val)
doExtFun' ws v = either (`doApp` v) (`doExtFun` v) ws

doExtFun :: AtStage (VSys Val -> Val -> Val)
doExtFun _  (VExtElm v _) = v
doExtFun ws (VNeu k)      = VExtFun ws k


--------------------------------------------------------------------------------
---- Coercion

-- | Smart constructor for VCoePartial
--
-- We maintain the following three invariants:
-- (1) At the current stage r0 != r1 (otherwise coe reduces to the identity)
-- (2) The head constructor of the line of types is known for VCoePartial.
--     Otherwise, the coersion is neutral, and given by VNeuCoePartial.
-- (3) In case of an Ext type, we keep the line fully forced.
--
-- We are very careful (TODO: is this neccessary?): We peak under the closure
-- to see the type. In the cases where we have restriction stable type formers,
-- we can safely construct a VCoePartial value to be evaluated when applied.
-- Otherwise, we force the delayed restriction, and check again.
--
-- TODO: what is with U?
vCoePartial :: AtStage (VI -> VI -> TrIntClosure -> Val)
vCoePartial r0 r1 | r0 === r1 = \l -> pId `doApp` (l $$ r0)
vCoePartial r0 r1 = go False
  where
    go :: Bool -> TrIntClosure -> Val
    go forced l@(TrIntClosure i a _) = case a of
      VSum{}   -> VCoePartial r0 r1 l
      VPi{}    -> VCoePartial r0 r1 l
      VSigma{} -> VCoePartial r0 r1 l
      VPath{}  -> VCoePartial r0 r1 l
      VNeu k   | forced     -> VNeuCoePartial r0 r1 (TrNeuIntClosure i k) 
      VExt{}   | forced     -> VCoePartial r0 r1 l -- we keep Ext types forced
      _        | not forced -> go True (force l)

doCoe :: AtStage (VI -> VI -> TrIntClosure -> Val -> Val)
doCoe r0 r1 = \case -- r0 != r1 by (1) ; by (2) these are all cases
  TrIntClosure z (VExt a bs) IdRestr -> doCoeExt r0 r1 z a bs -- by (3) restr (incl. eqs)
  TrIntClosure z (VSum _ _)  _       -> error "TODO: copy + simplify"
  l@(TrIntClosure _ VPi{}    _)      -> VCoe r0 r1 l
  l@(TrIntClosure _ VSigma{} _)      -> VCoe r0 r1 l
  l@(TrIntClosure _ VPath{}  _)      -> VCoe r0 r1 l

doCoeExt :: AtStage (VI -> VI -> Gen -> VTy -> VSys (VTy, Val, Val) -> Val -> Val)
doCoeExt = error "TODO: copy"


--------------------------------------------------------------------------------
---- HComp

-- | HComp where the system could be trivial
doHComp' :: AtStage (VI -> VI -> VTy -> Val -> Either TrIntClosure (VSys TrIntClosure) -> Val)
doHComp' r₀ r₁ a u0 = either ($$ r₁) (doHComp r₀ r₁ a u0)

doHComp :: AtStage (VI -> VI -> VTy -> Val -> VSys TrIntClosure -> Val)
doHComp r₀ r₁ _ u₀ _ | r₀ === r₁ = u₀
doHComp r₀ r₁ a u₀ tb = case a of
  VNeu k        -> VNeuHComp r₀ r₁ k u₀ tb
  VPi a b       -> VHCompPi r₀ r₁ a b u₀ tb
  VSigma a b    -> VHCompSigma r₀ r₁ a b u₀ tb
  VPath a a₀ a₁ -> VHCompPath r₀ r₁ a a₀ a₁ u₀ tb
  VSum d lbl    -> doHCompSum r₀ r₁ d lbl u₀ tb
  VExt a bs     -> doHCompExt r₀ r₁ a bs u₀ tb
  VU            -> doHCompU r₀ r₁ u₀ tb

---- Cases for positive types

doHCompSum :: AtStage (VI -> VI -> Val -> [VLabel] -> Val -> VSys TrIntClosure -> Val)
doHCompSum = error "TODO: copy"

doHCompExt :: AtStage (VI -> VI -> VTy -> VSys (VTy, Val, Val) -> Val -> VSys TrIntClosure -> Val)
doHCompExt = error "TODO: copy"

doHCompU :: AtStage (VI -> VI -> Val -> VSys TrIntClosure -> Val)
doHCompU = error "TODO: copy"


--------------------------------------------------------------------------------
---- Restriction Operations

instance Restrictable Val where
  act :: AtStage (Restr -> Val -> Val)
  act f = \case
    VU -> VU
    
    VPi a b -> VPi (a @ f) (b @ f)
    VLam cl -> VLam (cl @ f)

    VSigma a b -> VSigma (a @ f) (b @ f)
    VPair u v  -> VPair (u @ f) (v @ f)

    VPath a a0 a1  -> VPath (a @ f) (a0 @ f) (a1 @ f)
    VPLam cl p0 p1 -> VPLam (cl @ f) (p0 @ f) (p1 @ f)

    VCoePartial r0 r1 l -> vCoePartial (r0 @ f) (r1 @ f) (l @ f)

    VCoe r0 r1 l u0      -> vCoePartial (r0 @ f) (r1 @ f) (l @ f) `doApp` (u0 @ f)
    VHComp r0 r1 a u0 tb -> doHComp' (r0 @ f) (r1 @ f) (a @ f)(u0 @ f) (tb @ f)

    VExt a bs    -> vExt (a @ f) (bs @ f)
    VExtElm v ws -> vExtElm (v @ f) (ws @ f)

    VSum a lbl         -> VSum (a @ f) (lbl @ f)
    VCon c as          -> VCon c (as @ f)
    VSplitPartial v bs -> VSplitPartial (v @ f) (bs @ f)

    VNeu k -> either id VNeu (k @ f)    

instance Restrictable Neu where
  -- a neutral can get "unstuck" when restricted
  type Alt Neu = Either Val Neu

  act :: AtStage (Restr -> Neu -> Either Val Neu)
  act f = error "TODO: copy"

instance Restrictable a => Restrictable (VSys a) where
  type Alt (VSys a) = Either (Alt a) (VSys (Alt a))

  act :: Restr -> VSys a -> Either (Alt a) (VSys (Alt a))
  act f = error "TODO"

instance Restrictable VLabel where
  act :: AtStage (Restr -> VLabel -> VLabel)
  act f = fmap (@ f) 

instance Restrictable VBranch where
  act :: AtStage (Restr -> VBranch -> VBranch)
  act f = fmap (@ f)

instance Restrictable (Closure a) where
  -- | ((λx.t)ρ)f = (λx.t)(ρf)
  act :: AtStage (Restr -> Closure a -> Closure a)
  act f (Closure x t env) = Closure x t (env @ f)

instance Restrictable IntClosure where
  -- | ((λi.t)ρ)f = (λi.t)(ρf)
  act :: AtStage (Restr -> IntClosure -> IntClosure)
  act f (IntClosure x t env) = IntClosure x t (env @ f)

instance Restrictable SplitClosure where
  act :: AtStage (Restr -> SplitClosure -> SplitClosure)
  act f (SplitClosure xs t env) = SplitClosure xs t (env @ f)

instance Restrictable TrIntClosure where
  act :: AtStage (Restr -> TrIntClosure -> TrIntClosure)
  act f (TrIntClosure i v g) = TrIntClosure i v (f `comp` g) -- NOTE: original is flipped

instance Restrictable VTel where
  act :: AtStage (Restr -> VTel -> VTel )
  act f (VTel ts rho) = VTel ts (rho @ f)

instance Restrictable Env where
  act :: AtStage (Restr -> Env -> Env)
  act f = \case
    EmptyEnv          -> EmptyEnv
    EnvFib env x v    -> EnvFib (env @ f) x (v @ f)
    EnvDef env x t ty -> EnvDef (env @ f) x t ty 
    EnvInt env i r    -> EnvInt (env @ f) i (r @ f)

instance Restrictable a => Restrictable [a] where
  type Alt [a] = [Alt a]

  act :: AtStage (Restr -> [a] -> [Alt a])
  act f = map (@ f)

instance (Restrictable a, Restrictable b, Restrictable c) => Restrictable (a, b, c) where
  type Alt (a, b, c) = (Alt a, Alt b, Alt c)

  act :: AtStage (Restr -> (a, b, c) -> (Alt a, Alt b, Alt c))
  act f (x, y, z) = (x @ f, y @ f, z @ f)