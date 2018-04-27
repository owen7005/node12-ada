module Main where

import           Universum

import           Control.Monad.Random.Strict (evalRandT)
import           Control.DeepSeq (force)
import qualified Data.List.NonEmpty as NE
import qualified Data.Text as T
import           Data.Time.Units (Microsecond, convertUnit)
import qualified Options.Applicative as Opts
import           System.Random (newStdGen)
import           System.Wlog (LoggerName (..))

import           Mockable.CurrentTime (realTime)

import           Pos.AllSecrets (mkAllSecretsSimple)
import           Pos.Block.Error (ApplyBlocksException)
import           Pos.Block.Logic.VAR (verifyAndApplyBlocks, rollbackBlocks)
import           Pos.Core (Block)
import           Pos.Core.Common (BlockCount (..), unsafeCoinPortionFromDouble)
import           Pos.Core.Configuration (genesisBlockVersionData, genesisData, genesisSecretKeys)
import           Pos.Core.Genesis (FakeAvvmOptions (..), GenesisData (..), GenesisInitializer (..), TestnetBalanceOptions (..))
import           Pos.Core.Slotting (Timestamp (..))
import           Pos.DB.DB (initNodeDBs)
import           Pos.Generator.Block (BlockGenParams (..), TxGenParams (..), genBlocksNoApply)
import           Pos.Launcher.Configuration (ConfigurationOptions (..), HasConfigurations, defaultConfigurationOptions, withConfigurationsM)
import           Pos.Txp.Logic.Global (txpGlobalSettings)
import           Pos.Util.Chrono (OldestFirst (..), NE, nonEmptyNewestFirst)
import           Pos.Util.CompileInfo (HasCompileInfo, withCompileInfo, retrieveCompileTimeInfo)
import           Test.Pos.Block.Logic.Mode (BlockTestMode, TestParams (..), runBlockTestMode)

genesisInitializer :: GenesisInitializer
genesisInitializer = GenesisInitializer
    { giTestBalance = balance
    , giFakeAvvmBalance = FakeAvvmOptions
          { faoCount = 1
          , faoOneBalance = maxBound
          }
    , giAvvmBalanceFactor = unsafeCoinPortionFromDouble 0
    , giUseHeavyDlg = False
    , giSeed = 0
    }

balance :: TestnetBalanceOptions
balance = TestnetBalanceOptions
    { tboPoors = 1
    , tboRichmen = 1
    , tboTotalBalance = maxBound
    , tboRichmenShare = 1
    , tboUseHDAddresses = False
    }

generateBlocks :: HasConfigurations => BlockCount -> BlockTestMode (OldestFirst NE Block)
generateBlocks bCount = do
    g <- liftIO $ newStdGen
    let secretKeys =
            case genesisSecretKeys of
                Nothing ->
                    error "generateBlocks: no genesisSecretKeys"
                Just ks -> ks
    bs <- flip evalRandT g $ genBlocksNoApply
            (BlockGenParams
                { _bgpSecrets = mkAllSecretsSimple secretKeys
                , _bgpBlockCount = bCount
                , _bgpTxGenParams = TxGenParams
                    { _tgpTxCountRange = (0, 2)
                    , _tgpMaxOutputs = 2
                    }
                , _bgpInplaceDB = False
                , _bgpSkipNoKey = True
                , _bgpGenStakeholders = gdBootStakeholders genesisData
                , _bgpTxpGlobalSettings = txpGlobalSettings
                })
            maybeToList
    return $ OldestFirst $ NE.fromList bs


data BenchArgs = BenchArgs
    { baConfigPath :: FilePath
    , baConfigKey  :: Text
    , baBlockCount :: BlockCount
    , baRuns       :: Int
    }

configPathP :: Opts.Parser FilePath
configPathP = Opts.strOption $
       Opts.long "config"
    <> Opts.value "lib/configuration.yaml"
    <> Opts.showDefault
    <> Opts.help "path to yaml configuration file"

configKeyP :: Opts.Parser String
configKeyP = Opts.strOption $
       Opts.long "config-key"
    <> Opts.value "bench-validation"
    <> Opts.showDefault
    <> Opts.help "configuration key"

blockCountP :: Opts.Parser BlockCount
blockCountP = Opts.option (BlockCount <$> Opts.auto) $
       Opts.long "block-count"
    <> Opts.value 2000
    <> Opts.showDefault
    <> Opts.help "number of blocks to generate"

runsP :: Opts.Parser Int
runsP = Opts.option Opts.auto $
       Opts.long "runs"
    <> Opts.short 'r'
    <> Opts.value 100
    <> Opts.showDefault
    <> Opts.help "number of runs over generated blocks"

benchArgsParser :: Opts.Parser BenchArgs
benchArgsParser = BenchArgs
    <$> configPathP
    <*> (T.pack <$> configKeyP)
    <*> blockCountP
    <*> runsP

main :: IO ()
main = do
    args <- Opts.execParser
        $ Opts.info
            (benchArgsParser <**> Opts.helper)
            (Opts.fullDesc <> Opts.progDesc
                (  "The program generates given ammount of blocks and applies them. "
                )
            )
    startTime <- realTime
    let co = defaultConfigurationOptions
            { cfoFilePath = baConfigPath args
            , cfoKey = baConfigKey args
            , cfoSystemStart = Just (Timestamp startTime)
            }
    withCompileInfo $(retrieveCompileTimeInfo) $
        withConfigurationsM (LoggerName "verifyAndApplyBlocksBench") co $ \_ ->
            let tp = TestParams
                    { _tpStartTime = Timestamp (convertUnit startTime)
                    , _tpBlockVersionData = genesisBlockVersionData
                    , _tpGenesisInitializer = genesisInitializer
                    }
            in runBlockTestMode tp $ do
                -- initialize databasea
                initNodeDBs
                -- generate blocks and evaluate them to normal form
                liftIO $ putStrLn ("generating blocks" :: String)
                bs <- generateBlocks (baBlockCount args)
                let bss = force $ take (baRuns args) $ repeat bs

                putStrLn ("verifying blocks" :: String)
                (times, errs) <- unzip <$> traverse validate bss

                let -- drop first three results (if there are more than three results)
                    itimes :: [Float]
                    itimes = map realToFrac (if length times > 3 then drop 3 times else times)
                    -- mean time of execution
                    mean :: Float
                    mean = avarage itimes
                    -- standard deviation of the mean time distribution
                    stddev :: Float
                    stddev = sqrt . (\x -> x / realToFrac (length itimes - 1)) . avarage . map ((**2) . (-) mean) $ itimes
                putStrLn ("verification and application mean time: " ++ show mean ++ "msc stddev: " ++ show stddev :: String)

                -- print errors
                let errs' = catMaybes errs
                    errno = length errs'
                when (errno > 0) $ do
                    putStrLn $ " Verification/Application errors (" ++ shw errno ++ "):"
                    traverse_ (putStrLn . shw) errs
    where
        shw :: Show a => a -> String
        shw = show

        avarage :: [Float] -> Float
        avarage as = sum as / realToFrac (length as)

        validate
            :: ( HasConfigurations
               , HasCompileInfo
               )
            => OldestFirst NE Block
            -> BlockTestMode (Microsecond, Maybe ApplyBlocksException)
        validate blocks = do
            verStart <- realTime
            res <- verifyAndApplyBlocks False blocks >>= return . force
            verEnd <- realTime
            case res of
                Left _ -> return ()
                Right (_, blunds)
                    -> whenJust (nonEmptyNewestFirst blunds) rollbackBlocks
            return (verEnd - verStart, either Just (const Nothing) res)
