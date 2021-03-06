# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# differences from the SAScii package's read.SAScii() --
# 	4x faster
# 	no RAM issues
# 	decimal division isn't flexible
# 	must read in the entire table
#	requires RMonetDB and a few other packages
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

read.SAScii.monetdb <-
	function( 
		fn ,
		sas_ri , 
		beginline = 1 , 
		zipped = F , 
		# n = -1 , 			# no n parameter available for this - you must read in the entire table!
		lrecl = NULL , 
		# skip.decimal.division = NULL , skipping decimal division not an option
		tl = F ,			# convert all column names to lowercase?
		tablename ,
		overwrite = FALSE ,	# overwrite existing table?
		db					# database connection object -- read.SAScii.sql requires that dbConnect()
							# already be run before this function begins.
	) {

	
	# scientific notation contains a decimal point when converted to a character string..
	# so store the user's current value and get rid of it.
	user.defined.scipen <- getOption( 'scipen' )
	
	# set scientific notation to something impossibly high.  Inf doesn't work.
	options( scipen = 1000000 )
	
	
	# read.SAScii.monetdb depends on the SAScii package and the descr package
	# to install these packages, use the line:
	# install.packages( c( 'SAScii' , 'descr' ) )
	require(SAScii)
	require(descr)
	
	
	x <- parse.SAScii( sas_ri , beginline , lrecl )
	
	if( tl ) x$varname <- tolower( x$varname )
	
	#only the width field should include negatives
	y <- x[ !is.na( x[ , 'varname' ] ) , ]
	
	
	# deal with gaps in the data frame #
	num.gaps <- nrow( x ) - nrow( y )
	
	# if there are any gaps..
	if ( num.gaps > 0 ){
	
		# read them in as simple character strings
		x[ is.na( x[ , 'varname' ] ) , 'char' ] <- TRUE
		x[ is.na( x[ , 'varname' ] ) , 'divisor' ] <- 1
		
		# invert their widths
		x[ is.na( x[ , 'varname' ] ) , 'width' ] <- abs( x[ is.na( x[ , 'varname' ] ) , 'width' ] )
		
		# name them toss_1 thru toss_###
		x[ is.na( x[ , 'varname' ] ) , 'varname' ] <- paste( 'toss' , 1:num.gaps , sep = "_" )
		
		# and re-create y
		y <- x
	}
		
	#if the ASCII file is stored in an archive, unpack it to a temporary file and run that through read.fwf instead.
	if ( zipped ){
		#create a temporary file and a temporary directory..
		tf <- tempfile() ; td <- tempdir()
		#download the CPS repwgts zipped file
		download.file( fn , tf , mode = "wb" )
		#unzip the file's contents and store the file name within the temporary directory
		fn <- unzip( tf , exdir = td , overwrite = T )
	}

	
	# if the overwrite flag is TRUE, then check if the table is in the database..
	if ( overwrite ){
		# and if it is, remove it.
		if ( tablename %in% dbListTables( db ) ) dbRemoveTable( db , tablename )
		
		# if the overwrite flag is false
		# but the table exists in the database..
	} else {
		if ( tablename %in% dbListTables( db ) ) stop( "table with this name already in database" )
	}
	
	if ( sum( grepl( 'sample' , tolower( y$varname ) ) ) > 0 ){
		print( 'warning: variable named sample not allowed in monetdb' )
		print( 'changing column name to sample_' )
		y$varname <- gsub( 'sample' , 'sample_' , y$varname )
	}
	
	fields <- y$varname

	colTypes <- ifelse( !y[ , 'char' ] , 'DOUBLE PRECISION' , 'VARCHAR(255)' )
	

	colDecl <- paste( fields , colTypes )

	sql <-
		sprintf(
			paste(
				"CREATE TABLE" ,
				tablename ,
				"(%s)"
			) ,
			paste(
				colDecl ,
				collapse = ", "
			)
		)
	
	dbSendUpdate( db , sql )

	# create a second temporary file
	tf2 <- tempfile()
	
	# create a third temporary file
	tf3 <- tempfile()
	
	# starts and ends
	w <- abs ( x$width )
	s <- 1
	e <- w[ 1 ]
	for ( i in 2:length( w ) ) {
		s[ i ] <- s[ i - 1 ] + w[ i - 1 ]
		e[ i ] <- e[ i - 1 ] + w[ i ]
	}
	
	# create another file connection to the temporary file to store the fwf2csv output..
	zz <- file( tf3 , open = 'wt' )
	sink( zz , type = 'message' )
	
	# convert the fwf to a csv
	# verbose = TRUE prints a message, which has to be captured.
	fwf2csv( fn , tf2 , names = x$varname , begin = s , end = e , verbose = TRUE )

	# stop storing the output
	sink( type = "message" )
	unlink( tf3 )
	
	# read the contents of that message into a character string
	zzz <- readLines( tf3 )
	
	# read it up to the first space..
	last.char <- which( strsplit( zzz , '')[[1]]==' ')
	
	# ..and that's the number of lines in the file
	num.lines <- substr( zzz , 1 , last.char - 1 )
	
	# in speed tests, adding the exact number of lines in the file was much faster
	# than setting a very high number and letting it finish..
	
	# pull the csv file into the database
	dbSendUpdate( db , paste0( "copy " , num.lines , " offset 2 records into " , tablename , " from '" , tf2 , "' using delimiters '\t' NULL AS ''" ) )
	
	# delete the temporary file from the hard disk
	file.remove( tf2 )
		
	# loop through all columns to:
		# convert to numeric where necessary
		# divide by the divisor whenever necessary
	for ( l in 1:nrow(y) ){
	
		if ( 
			( y[ l , "divisor" ] != 1 ) & 
			!( y[ l , "char" ] )
		) {
			
			sql <- 
				paste( 
					"UPDATE" , 
					tablename , 
					"SET" , 
					y[ l , 'varname' ] , 
					"=" ,
					y[ l , 'varname' ] , 
					"*" ,
					y[ l , "divisor" ]
				)
				
			dbSendUpdate( db , sql )
			
		}
			
		cat( "  current progress: " , l , "of" , nrow( y ) , "columns processed.                    " , "\r" )
	
	}
	
	# eliminate gap variables.. loop through every gap
	if ( num.gaps > 0 ){
		for ( i in seq( num.gaps ) ) {
		
			# create a SQL query to drop these columns
			sql.drop <- paste0( "ALTER TABLE " , tablename , " DROP toss_" , i )
			
			# and drop them!
			dbSendUpdate( db , sql.drop )
		}
	}
	
	# reset scientific notation length
	options( scipen = user.defined.scipen )
	
	TRUE
}
