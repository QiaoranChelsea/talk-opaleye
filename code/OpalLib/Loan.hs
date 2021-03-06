{-# LANGUAGE Arrows                #-}
{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE MultiParamTypeClasses #-}
module OpalLib.Loan where

import Prelude hiding (null)

import Control.Arrow                   (returnA)
import Control.Lens                    (makeLenses,(^.),(.~),(%~),to,_1)
import Control.Monad                   (void)
import Data.Time                       (UTCTime)
import Data.Profunctor.Product.TH      (makeAdaptorAndInstance)
import Opaleye
import Opaleye.Classy

import OpalLib.Ids
import OpalLib.Date
import OpalLib.Accession
import OpalLib.Person
import OpalLib.Book

data Loan' a b c d e f = Loan
  { _loanId          :: a
  , _loanPersonId    :: b
  , _loanAccessionId :: c
  , _loanBorrowed    :: d
  , _loanDue         :: e
  , _loanReturned    :: f
  } deriving Show
makeLenses ''Loan'

makeAdaptorAndInstance "pLoan" ''Loan'

type LoanColumns = Loan'
  LoanIdColumn
  PersonIdColumn
  AccessionIdColumn
  (Column PGTimestamptz)
  (Column PGTimestamptz)
  (Column (Nullable PGTimestamptz))

type LoanInsertColumns = Loan'
  LoanIdColumnMaybe
  PersonIdColumn
  AccessionIdColumn
  (Column PGTimestamptz)
  (Column PGTimestamptz)
  (Column (Nullable PGTimestamptz))

type Loan = Loan'
  LoanId
  PersonId
  AccessionId
  UTCTime
  UTCTime
  (Maybe UTCTime)

type LoanColumnsNullable = Loan'
  LoanIdColumnNullable
  PersonIdColumnNullable
  AccessionIdColumnNullable
  (Column (Nullable PGTimestamptz))
  (Column (Nullable PGTimestamptz))
  (Column (Nullable PGTimestamptz))

type FullLoanColumns =
  (LoanColumns,AccessionIdColumn,BookColumns,PersonColumns)

type FullLoan = (Loan,AccessionId,Book,Person)

loanTable :: Table LoanInsertColumns LoanColumns
loanTable = Table "loan" $ pLoan Loan
  { _loanId          = pLoanId . LoanId $ optional "id"
  , _loanPersonId    = pPersonId . PersonId $ required "person_id"
  , _loanAccessionId = pAccessionId . AccessionId $ required "accession_id"
  , _loanBorrowed    = required "borrowed"
  , _loanDue         = required "due"
  , _loanReturned    = required "returned"
  }

loanQuery :: Query LoanColumns
loanQuery = queryTable loanTable

loansAll :: CanOpaleye c e m => m [Loan]
loansAll = liftQuery loanQuery

loanPersonQuery :: QueryArr LoanColumns PersonColumns
loanPersonQuery = proc (l) -> do
  p <- personQuery -< ()
  restrict -< l^.loanPersonId.to unPersonId .== p^.personId.to unPersonId
  returnA -< p

loanAccessionQuery :: QueryArr LoanColumns (AccessionIdColumn,BookColumns)
loanAccessionQuery = proc (l) -> do
  t <- accessionsWithBookQuery -< ()
  restrict -< l^.loanAccessionId.to unAccessionId .== t^._1.to unAccessionId
  returnA -< t

fullLoanQuery :: Query FullLoanColumns
fullLoanQuery = proc () -> do
  l        <- loanQuery          -< ()
  p        <- loanPersonQuery    -< l
  (aId,b)  <- loanAccessionQuery -< l
  returnA  -< (l,aId,b,p)

findLoanByLoanIdQuery :: LoanIdColumn -> Query FullLoanColumns
findLoanByLoanIdQuery lId = proc () -> do
  t <- fullLoanQuery -< ()
  restrict -< t^._1.loanId.to unLoanId .== unLoanId lId
  returnA  -< t

findLoanByLoanId
  :: CanOpaleye c e m
  => LoanId
  -> m (Maybe FullLoan)
findLoanByLoanId = liftQueryFirst . findLoanByLoanIdQuery . constant

borrow
  :: CanOpaleye c e m
  => AccessionId 
  -> PersonId
  -> UTCTime
  -> UTCTime
  -> m LoanId
borrow aId pId b d =
  fmap head $ liftInsertReturning loanTable (^.loanId) $ Loan
    { _loanId          = LoanId Nothing
    , _loanPersonId    = constant pId
    , _loanAccessionId = constant aId
    , _loanBorrowed    = constant b
    , _loanDue         = constant d
    , _loanReturned    = null
    }

loanOutstanding :: LoanColumns -> Column PGBool
loanOutstanding l = l^.loanReturned.to isNull

restrictLoansCurrent :: QueryArr LoanColumns ()
restrictLoansCurrent = proc (l) -> do
  restrict -< loanOutstanding l

loansOutstandingQuery :: Query FullLoanColumns
loansOutstandingQuery = proc () -> do
  t <- fullLoanQuery -< ()
  restrictLoansCurrent -< t^._1
  returnA -< t

loansOutstanding :: CanOpaleye c e m => m [FullLoan]
loansOutstanding = liftQuery loansOutstandingQuery

loansOverdueQuery :: Query FullLoanColumns
loansOverdueQuery = proc () -> do
  t <- fullLoanQuery -< ()
  restrictLoansCurrent -< t^._1
  restrict -< t^._1.loanDue .<= now
  returnA -< t

loansOverdue :: CanOpaleye c e m => m [FullLoan]
loansOverdue = liftQuery loansOverdueQuery

loanReturn :: CanOpaleye c e m => LoanId -> UTCTime -> m ()
loanReturn lId r = void $ liftUpdate loanTable
  (  (loanId %~ pLoanId (LoanId Just))
   . (loanReturned .~ toNullable (constant r))
  )
  (\ l -> l^.loanId.to unLoanId .== unLoanId (constant lId))
