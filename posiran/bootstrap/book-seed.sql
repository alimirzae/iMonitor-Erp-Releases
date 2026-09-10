-- Posiran ERP sanitized initial BookDb bootstrap seed
-- Schema is generated from the exact BookDbContext migrations of each source release.
-- This file only provides minimal safe lookup/default data for دفتر اصلی.
-- Installer replaces __BOOK_ID__ and __BRANCH_ID__ before import.

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS=0;
SET @book_id = '__BOOK_ID__';
SET @branch_id = __BRANCH_ID__;

INSERT INTO `invoicetypes`
(`Id`,`Name`,`Description`,`IsInternal`,`EffectOnAmount`,`EffectOnPrice`,`SyncId`,`CreatedByBranchId`,`LastModifiedByBranchId`,`LastModifiedAt`,`IsDeleted`,`BookId`) VALUES
(1,'بی اثر','',0,0,0,'bootstrap-invoice-1',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(10,'فاکتور فروش','',0,1,0,'bootstrap-invoice-10',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(11,'برگشت از فروش','',0,-1,0,'bootstrap-invoice-11',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(20,'فاکتور خرید','',0,-1,1,'bootstrap-invoice-20',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(21,'برگشت از خرید','',0,1,-1,'bootstrap-invoice-21',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(30,'قبض انبار','',1,1,0,'bootstrap-invoice-30',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(31,'حواله انبار','',1,-1,0,'bootstrap-invoice-31',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(32,'حواله انتقال انبار','',1,-1,0,'bootstrap-invoice-32',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(33,'قبض انتقال انبار','',1,1,0,'bootstrap-invoice-33',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(40,'تعدیل افزایشی','',1,1,0,'bootstrap-invoice-40',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(41,'تعدیل کاهشی','',1,-1,0,'bootstrap-invoice-41',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(50,'موجودی اول دوره','',1,1,1,'bootstrap-invoice-50',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id)
ON DUPLICATE KEY UPDATE `Name`=VALUES(`Name`),`Description`=VALUES(`Description`),`IsDeleted`=0,`BookId`=VALUES(`BookId`);

INSERT INTO `paymenttypes`
(`Id`,`Name`,`Description`,`SyncId`,`CreatedByBranchId`,`LastModifiedByBranchId`,`LastModifiedAt`,`IsDeleted`,`BookId`) VALUES
(1,'نقد','پرداخت نقدی','bootstrap-payment-1',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(2,'کارتخوان','پرداخت با پوز','bootstrap-payment-2',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(3,'چک','پرداخت با چک','bootstrap-payment-3',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(4,'حواله','پرداخت با حواله','bootstrap-payment-4',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(5,'کارت هدیه','پرداخت با کارت هدیه','bootstrap-payment-5',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(99,'نامشخص','نامشخص','bootstrap-payment-99',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id)
ON DUPLICATE KEY UPDATE `Name`=VALUES(`Name`),`Description`=VALUES(`Description`),`IsDeleted`=0,`BookId`=VALUES(`BookId`);

INSERT INTO `saletypes`
(`Id`,`Name`,`Description`,`MinimumDiscountPercentage`,`MaximumDiscountPercentage`,`CreatedAt`,`SyncId`,`CreatedByBranchId`,`LastModifiedByBranchId`,`LastModifiedAt`,`IsDeleted`,`BookId`) VALUES
(1,'فروش عادی','فروش عادی',0.0,100.0,UTC_TIMESTAMP(6),'bootstrap-sale-1',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(2,'عمده','عمده',0.0,100.0,UTC_TIMESTAMP(6),'bootstrap-sale-2',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(3,'همکار','همکار',0.0,100.0,UTC_TIMESTAMP(6),'bootstrap-sale-3',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id)
ON DUPLICATE KEY UPDATE `Name`=VALUES(`Name`),`Description`=VALUES(`Description`),`IsDeleted`=0,`BookId`=VALUES(`BookId`);

INSERT INTO `transactiontypes`
(`Id`,`Name`,`Description`,`EffectOnQuantity`,`EffectOnPrice`,`SyncId`,`CreatedByBranchId`,`LastModifiedByBranchId`,`LastModifiedAt`,`IsDeleted`,`BookId`) VALUES
(1,'اول دوره','موجودی اول دوره',1,1,'bootstrap-transaction-1',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(2,'فاکتور خرید','فاکتور خرید عادی',1,1,'bootstrap-transaction-2',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(3,'قبض انبار','قبض انبار عادی',1,1,'bootstrap-transaction-3',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(4,'برگشت از فروش','برگشت از فروش',1,0,'bootstrap-transaction-4',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(5,'برگشت از حواله انبار','برگشت از حواله انبار',1,0,'bootstrap-transaction-5',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(50,'فاکتور فروش','فاکتور فروش عادی',-1,1,'bootstrap-transaction-50',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(51,'برگشت از قبض انبار','برگشت از قبض انبار',-1,0,'bootstrap-transaction-51',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(90,'پیش فاکتور','پیش فاکتور عادی',0,0,'bootstrap-transaction-90',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id)
ON DUPLICATE KEY UPDATE `Name`=VALUES(`Name`),`Description`=VALUES(`Description`),`IsDeleted`=0,`BookId`=VALUES(`BookId`);

INSERT INTO `units`
(`Id`,`Name`,`Sign`,`Description`,`UpdatedAt`,`CreatedAt`,`SyncId`,`CreatedByBranchId`,`LastModifiedByBranchId`,`LastModifiedAt`,`IsDeleted`,`BookId`) VALUES
(1,'عدد','عدد',NULL,NULL,UTC_TIMESTAMP(6),'bootstrap-unit-1',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(2,'دستگاه','دستگاه',NULL,NULL,UTC_TIMESTAMP(6),'bootstrap-unit-2',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(3,'کیلو','Kg',NULL,NULL,UTC_TIMESTAMP(6),'bootstrap-unit-3',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(4,'لیتر','Litr',NULL,NULL,UTC_TIMESTAMP(6),'bootstrap-unit-4',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(5,'بسته','بسته',NULL,NULL,UTC_TIMESTAMP(6),'bootstrap-unit-5',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(6,'کارتن','کارتن',NULL,NULL,UTC_TIMESTAMP(6),'bootstrap-unit-6',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(7,'قراص','قراص',NULL,NULL,UTC_TIMESTAMP(6),'bootstrap-unit-7',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id),
(8,'متر','متر',NULL,NULL,UTC_TIMESTAMP(6),'bootstrap-unit-8',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id)
ON DUPLICATE KEY UPDATE `Name`=VALUES(`Name`),`Sign`=VALUES(`Sign`),`IsDeleted`=0,`BookId`=VALUES(`BookId`);

INSERT INTO `warehouses`
(`Id`,`Name`,`Address`,`GPSLocation`,`CreatedAt`,`IsDefault`,`IsActive`,`Code`,`Phone`,`Manager`,`Description`,`UpdatedAt`,`SyncId`,`CreatedByBranchId`,`LastModifiedByBranchId`,`LastModifiedAt`,`IsDeleted`,`BookId`) VALUES
(1,'انبار اصلی','','',UTC_TIMESTAMP(6),1,1,'MAIN',NULL,NULL,'انبار اولیه',NULL,'bootstrap-warehouse-1',@branch_id,@branch_id,UTC_TIMESTAMP(6),0,@book_id)
ON DUPLICATE KEY UPDATE `Name`=VALUES(`Name`),`IsDefault`=1,`IsActive`=1,`IsDeleted`=0,`BookId`=VALUES(`BookId`);

SET FOREIGN_KEY_CHECKS=1;
