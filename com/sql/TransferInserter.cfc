<!--- Document Information -----------------------------------------------------

Title:      TransferInserter.cfc

Author:     Mark Mandel
Email:      mark@compoundtheory.com

Website:    http://www.compoundtheory.com

Purpose:    Inserts a transfer's details into the DB

Usage:

Modification Log:

Name			Date			Description
================================================================================
Mark Mandel		12/08/2005		Created

------------------------------------------------------------------------------->

<cfcomponent name="TransferInserter" hint="Inserts a transfer's details into the DB" extends="AbstractBaseTransfer">

<!------------------------------------------- PUBLIC ------------------------------------------->
<cffunction name="init" hint="Constructor" access="public" returntype="TransferInserter" output="false">
	<cfargument name="datasource" hint="The datasource BO" type="transfer.com.sql.Datasource" required="Yes" _autocreate="false">
	<cfargument name="objectManager" hint="Need to object manager for making queries" type="transfer.com.object.ObjectManager" required="Yes" _autocreate="false">
	<cfargument name="xmlFileReader" hint="The file path to the config file" type="transfer.com.io.XMLFileReader" required="Yes" _autocreate="false">
	<cfargument name="utility" hint="The utility class" type="transfer.com.util.Utility" required="Yes" _autocreate="false">
	<cfargument name="nullable" hint="The nullable class" type="transfer.com.sql.Nullable" required="Yes" _autocreate="false">
	<cfargument name="queryExecutionPool" hint="the query execution pool" type="transfer.com.sql.collections.QueryExecutionPool" required="Yes">
	<cfargument name="queryCache" hint="the query object cache" type="transfer.com.sql.collections.QueryCache" required="Yes">
	<cfargument name="transaction" type="transfer.com.sql.transaction.Transaction" required="true" _autocreate="false">
	<cfscript>
		super.init(argumentCollection=arguments);

		setNullable(arguments.nullable);
		setIDGenerator(createObject("component", "transfer.com.sql.IDGenerator").init(5, arguments.datasource, arguments.xmlFileReader, arguments.utility));

		return this;
	</cfscript>
</cffunction>

<cffunction name="create" hint="Inserts the transfer into the DB" access="public" returntype="void" output="false">
	<cfargument name="transfer" hint="The transfer object to insert" type="transfer.com.TransferObject" required="Yes">
	<cfargument name="useTransaction" hint="Whether or not to use an internal transaction block" type="boolean" required="true">
	<cfscript>
		if(arguments.useTransaction)
		{
			getTransaction().execute(this, "insertBlock", arguments);
		}
		else
		{
			insertBlock(arguments.transfer);
		}
	</cfscript>
</cffunction>

<!------------------------------------------- PACKAGE ------------------------------------------->

<!------------------------------------------- PRIVATE ------------------------------------------->

<cffunction name="insertBlock" hint="run the insert" access="private" returntype="void" output="false">
	<cfargument name="transfer" hint="The transfer object to insert" type="transfer.com.TransferObject" required="Yes">
	<cfscript>
		insertBasic(arguments.transfer);
		insertManyToMany(arguments.transfer);
	</cfscript>
</cffunction>

<cffunction name="setGeneratedPrimaryKey" hint="sets the TransferObject's primary key value with one generated by Transfer" access="private" returntype="void" output="false">
	<cfargument name="transfer" hint="The transfer object to insert" type="transfer.com.TransferObject" required="Yes">
	<cfscript>
		var object = getObjectManager().getObject(arguments.transfer.getClassName());
		var id = 0;

		//get me an id please, numeric or UUID, or GUID
		switch(object.getPrimaryKey().getType())
		{
			case "numeric":
				id = getIDGenerator().getNumericID(object);
			break;

			case "uuid":
				id = getIDGenerator().getUUID();
			break;

			case "guid":
				id = getIDGenerator().getGUID();
			break;

			default:
				createObject("component", "transfer.com.sql.exception.UnsupportedAutoGenerateTypeException").init(object);
			break;
		}

		invokeSetPrimaryKey(arguments.transfer, id);
	</cfscript>
</cffunction>

<cffunction name="insertBasic" hint="Insert the single table part of the query. populates the transfer with it's primary key" access="private" returntype="void" output="false">
	<cfargument name="transfer" hint="The transfer object to insert" type="transfer.com.TransferObject" required="Yes">
	<cfscript>
		var object = getObjectManager().getObject(arguments.transfer.getClassName());
		var primaryKeyHasValue = primaryKeyHasValue(arguments.transfer);
		var primaryKey = object.getPrimaryKey();
		var generateKey = (NOT primaryKey.getIsComposite()) AND primaryKey.getGenerate() AND (NOT primaryKeyHasValue);
		var populateKey = (NOT primaryKey.getIsComposite()) AND (NOT primaryKey.getGenerate()) AND (NOT primaryKeyHasValue);
		var query = 0;
		var queryExec = 0;
		var qBeforeInsertTransfer = 0;
		var qAfterInsertTransfer = 0;
		var qInsertTransfer = 0;

		if(generateKey)
		{
			setGeneratedPrimaryKey(arguments.transfer);
		}

		if(populateKey)
		{
			query = buildSQLBeforeInsert(object);
			if(isObject(query))
			{
				queryExec = query.createExecution();
				qBeforeInsertTransfer = queryExec.executeQuery();

				getQueryExecutionPool().recycle(queryExec);

				invokeSetPrimaryKey(arguments.transfer, qBeforeInsertTransfer.id);
				primaryKeyHasValue = true;
			}
		}

		query = buildInsertBasicQuery(arguments.transfer, primaryKeyHasValue, generateKey, populateKey);

		qInsertTransfer = executeBasicInsert(arguments.transfer, query, primaryKeyHasValue, generateKey, populateKey);

		//maybe you need to go outside to populate the primary key
		if(populateKey)
		{
			query = buildSQLAfterInsert(object);
			if(isObject(query))
			{
				queryExec = query.createExecution();
				qAfterInsertTransfer = queryExec.executeQuery();

				getQueryExecutionPool().recycle(queryExec);
			}
		}

		//if not auto generating -
		if(NOT primaryKeyHasValue AND populateKey)
		{
			//check then qInside, then qAfter, if none, throw an exception
			if(IsQuery(qInsertTransfer) AND ListFindNoCase(qInsertTransfer.columnList, "id"))
			{
				invokeSetPrimaryKey(arguments.transfer, qInsertTransfer.id);
			}
			else
			{
				invokeSetPrimaryKey(arguments.transfer, qAfterInsertTransfer.id);
			}
		}
	</cfscript>
</cffunction>

<cffunction name="buildInsertBasicQuery" hint="builds a basic query" access="private" returntype="transfer.com.sql.Query" output="false">
	<cfargument name="transfer" hint="The transfer object to insert" type="transfer.com.TransferObject" required="Yes">
	<cfargument name="primaryKeyHasValue" hint="whether the primary key already has a value" type="boolean" required="Yes">
	<cfargument name="generateKey" hint="whether or not to generate a key" type="string" required="Yes">
	<cfargument name="populatePrimaryKey" hint="whether or not to populate the primary key with a value" type="boolean" required="Yes">

	<cfscript>
		var object = 0;
		var composite = 0;
		var key = "basic.insert.";
		var query = 0;
		var iterator = 0;
		var property = 0;
		var isFirst = true;
		var manytoone = 0;
		var parentOneToMany = 0;

		if(arguments.populatePrimaryKey)
		{
			key = key & "populatePrimaryKey.";
		}

		if(arguments.primaryKeyHasValue)
		{
			key = key & "primaryKeyHasValue.";
		}

		if(arguments.generateKey)
		{
			key = key & "generateKey.";
		}

		key = key & arguments.transfer.getClassName();
	</cfscript>
	<cfif NOT getQueryCache().hasQuery(key)>
		<cflock name="transfer.#key#" throwontimeout="true" timeout="60">
		<cfscript>
			if(NOT getQueryCache().hasQuery(key))
			{
				object = getObjectManager().getObject(arguments.transfer.getClassName());

				query = createObject("component", "transfer.com.sql.Query").init(getQueryExecutionPool());
				query.start();

				query.appendSQL("INSERT INTO " & object.getTable() & "(");
				query.appendSQL(createColumnList(object, arguments.primaryKeyHasValue, arguments.generateKey));

				query.appendSQL(") VALUES (");

				iterator = object.getPropertyIterator();

				//properties
				while(iterator.hasNext())
				{
					property = iterator.next();

					//ignore ignore-true
					if(NOT property.getIgnoreInsert())
					{
						isFirst = commaSeperator(query, isFirst);
						query.mapParam("property:" & property.getName(), property.getType());
					}
				}

				//many to one
				iterator = object.getManyToOneIterator();
				while(iterator.hasNext())
				{
					manytoone = iterator.next();
					composite = getObjectManager().getObject(manyToOne.getLink().getTo());

					isFirst = commaSeperator(query, isFirst);
					query.mapParam("manytoone:" & manytoone.getName(), composite.getPrimaryKey().getType());
				}

				//parent one to many
				iterator = object.getParentOnetoManyIterator();

				while(iterator.hasNext())
				{
					parentOneToMany = iterator.next();
					composite = getObjectManager().getObject(parentOneToMany.getLink().getTo());
					isFirst = commaSeperator(query, isFirst);
					query.mapParam("parentonetomany:" & composite.getObjectName(), composite.getPrimaryKey().getType());
				}

				if(arguments.generateKey OR arguments.primaryKeyHasValue)
				{
					isFirst = commaSeperator(query, isFirst);
					mapPrimaryKey(query=query, object=object, ignoreColumn=true);
				}

				query.appendSQL(")");

				//if populate, --->
				if(arguments.populatePrimaryKey)
				{
					buildSqlInsideInsert(query, object);
				}

				query.stop();
				getQueryCache().addQuery(key, query);
			}
		</cfscript>
		</cflock>
	</cfif>
	<cfreturn getQueryCache().getQuery(key) />
</cffunction>

<cffunction name="executeBasicInsert" hint="executes the basic insert" access="private" returntype="any" output="false">
	<cfargument name="transfer" hint="The transfer object to insert" type="transfer.com.TransferObject" required="Yes">
	<cfargument name="query" hint="The query to execute" type="transfer.com.sql.Query" required="Yes">
	<cfargument name="primaryKeyHasValue" hint="whether the primary key already has a value" type="boolean" required="Yes">
	<cfargument name="generateKey" hint="whether or not to generate a key" type="string" required="Yes">
	<cfargument name="populatePrimaryKey" hint="whether or not to populate the primary key with a value" type="boolean" required="Yes">
	<cfscript>
		var local = StructNew();
		var queryExec = arguments.query.createExecution();
		var object = getObjectManager().getObject(arguments.transfer.getClassName());
		var iterator = object.getPropertyIterator();
		var property = 0;
		var args = 0;
		var manytoone = 0;
		var parentonetomany = 0;
		var composite = 0;
		var linkObject = 0;

		//properties
		while(iterator.hasNext())
		{
			property = iterator.next();

			if(NOT property.getIgnoreInsert())
			{
				args = StructNew();

				args.name = "property:" & property.getName();
				args.value = getMethodInvoker().invokeMethod(arguments.transfer, "get" & property.getName());

				if(property.getIsNullable())
				{
					args.isNull = getNullable().checkNullValue(arguments.transfer, property, args.value);
				}
				queryExec.setParam(argumentCollection=args);
			}
		}

		//many to one
		iterator = object.getManyToOneIterator();
		while(iterator.hasNext())
		{
			manytoone = iterator.next();

			args = StructNew();
			args.name = "manytoone:" & manytoone.getName();
			args.isNull = NOT getMethodInvoker().invokeMethod(arguments.transfer, "has" & manyToOne.getName());

			if(NOT args.isNull)
			{
				composite = getMethodInvoker().invokeMethod(transfer, "get" & manyToOne.getName());

				if(not composite.getIsPersisted())
				{
					createObject("component", "transfer.com.sql.exception.ManyToOneNotCreatedException").init(object, composite);
				}

				args.value = invokeGetPrimaryKey(composite);
			}
			queryExec.setParam(argumentCollection=args);
		}

		//parent one to many
		iterator = object.getParentOnetoManyIterator();

		while(iterator.hasNext())
		{
			parentonetomany = iterator.next();
			linkObject = getObjectManager().getObject(parentOneToMany.getLink().getTo());

			args = StructNew();

			args.name = "parentonetomany:" & linkObject.getObjectName();
			args.isNull = NOT getMethodInvoker().invokeMethod(arguments.transfer, "hasParent" & linkObject.getObjectName());

			if(NOT args.isNull)
			{
				composite = getMethodInvoker().invokeMethod(arguments.transfer, "getParent" & linkObject.getObjectName());

				//make sure it's in the DB
				if(not composite.getIsPersisted())
				{
					createObject("component", "transfer.com.sql.exception.ParentOneToManyNotCreatedException").init(object, composite);
				}

				args.value = invokeGetPrimaryKey(composite);
			}
			queryExec.setParam(argumentCollection=args);
		}

		if(arguments.generateKey OR arguments.primaryKeyHasValue)
		{
			setPrimaryKey(queryExec=queryExec, transfer=arguments.transfer, setOperator=false);
		}

		local.qResult = queryExec.executeQuery();

		getQueryExecutionPool().recycle(queryExec);

		if(StructKeyExists(local, "qResult"))
		{
			return local.qResult;
		}

		return 0;
	</cfscript>
</cffunction>

<cffunction name="insertManyToMany" hint="Updates the many to many portion of the transfer" access="private" returntype="void" output="false">
	<cfargument name="transfer" hint="The transferObject to update" type="transfer.com.TransferObject" required="Yes">
	<cfscript>
		var object = getObjectManager().getObject(arguments.transfer.getClassName());
		var query = 0;
		var iterator = object.getManyToManyIterator();
		var manytomany = 0;
		var queryExec = 0;
		var collectionIterator = 0;
		var compositeObject = 0;

		while(iterator.hasNext())
		{
			manytomany = iterator.next();
			query = buildInsertManyToMany(object, manytomany);

			queryExec = query.createExecution();

			collectionIterator = getMethodInvoker().invokeMethod(transfer, "get" & manyToMany.getName() & "Iterator");

			while(collectionIterator.hasNext())
			{
				compositeObject = collectionIterator.next();

				if(NOT compositeObject.getIsPersisted())
				{
					createObject("component", "transfer.com.sql.exception.ManyToManyNotCreatedException").init(object, compositeObject);
				}

				if(manytomany.getLinkFrom().getTo() eq arguments.transfer.getClassName())
				{
					queryExec.setParam("from-key:" & arguments.transfer.getClassName(), invokeGetPrimaryKey(arguments.transfer));
					queryExec.setParam("to-key:" & compositeObject.getClassName(), invokeGetPrimaryKey(compositeObject));
				}
				else if(manytomany.getLinkTo().getTo() eq arguments.transfer.getClassName())
				{
					queryExec.setParam("to-key:" & arguments.transfer.getClassName(), invokeGetPrimaryKey(arguments.transfer));
					queryExec.setParam("from-key:" & compositeObject.getClassName(), invokeGetPrimaryKey(compositeObject));
				}

				queryExec.execute();

			}

			getQueryExecutionPool().recycle(queryExec);
		}
	</cfscript>
</cffunction>

<cffunction name="buildInsertManyToMany" hint="builds tehe query for inserting a many to many" access="public" returntype="transfer.com.sql.Query" output="false">
	<cfargument name="object" hint="the object that the insert is for" type="transfer.com.object.Object" required="Yes">
	<cfargument name="manytomany" hint="the many to many that is being inserted" type="transfer.com.object.ManyToMany" required="Yes">
	<cfscript>
		var query = 0;
		var key = "insert.manytomany." & arguments.object.getClassName() & "." & arguments.manytomany.getName();
		var composite = 0;
	</cfscript>
	<cfif NOT getQueryCache().hasQuery(key)>
		<cflock name="transfer.#key#" throwontimeout="true" timeout="60">
			<cfscript>
				if(NOT getQueryCache().hasQuery(key))
				{
					query = createObject("component", "transfer.com.sql.Query").init(getQueryExecutionPool());

					query.start();
					query.appendSQL("INSERT INTO ");
					query.appendSQL(arguments.manytomany.getTable());
					query.appendSQL(" ( ");
					query.appendSQL(arguments.manyToMany.getLinkFrom().getColumn());
					query.appendSQL(" , ");
					query.appendSQL(arguments.manyToMany.getLinkTo().getColumn());
					query.appendSQL(" ) ");
					query.appendSQL(" VALUES ");
					query.appendSQL(" ( ");

					composite = getObjectManager().getObject(arguments.manytomany.getLinkFrom().getTo());
					query.mapParam("from-key:" & composite.getClassName(), composite.getPrimaryKey().getType());

					query.appendSQL(" , ");

					composite = getObjectManager().getObject(arguments.manytomany.getLinkTo().getTo());
					query.mapParam("to-key:" & composite.getClassName(), composite.getPrimaryKey().getType());

					query.appendSQL(" ) ");
					query.stop();

					getQueryCache().addQuery(key, query);
				}
			</cfscript>
		</cflock>
	</cfif>
	<cfreturn getQueryCache().getQuery(key) />
</cffunction>

<cffunction name="buildSQLBeforeInsert" hint="Overwrite to run SQL directly before the insert query (no generation). Should select a 'id' column for id population" access="private" returntype="any" output="false">
	<cfargument name="object" hint="The object that is being inserted" type="transfer.com.object.Object" required="Yes">
	<cfreturn 0>
</cffunction>

<cffunction name="buildSqlInsideInsert" hint="Overwrite method to run SQL inside the insert query (with no generation), and before the end of the cfquery block. Should select a 'id' column for id population" access="private" returntype="void" output="false">
	<cfargument name="query" hint="the query object" type="transfer.com.sql.Query" required="Yes">
	<cfargument name="object" hint="The oject that is being inserted" type="transfer.com.object.Object" required="Yes">
</cffunction>

<cffunction name="buildsqlAfterInsert" hint="Overwrite to run SQL directly after the insert query (no generation). Should select a 'id' column for id population" access="private" returntype="any" output="false">
	<cfargument name="object" hint="The oject that is being inserted" type="transfer.com.object.Object" required="Yes">
	<cfreturn 0>
</cffunction>

<cffunction name="createColumnList" hint="Creates the column list to insert" access="private" returntype="string" output="false">
	<cfargument name="object" hint="The oject that is being inserted" type="transfer.com.object.Object" required="Yes">
	<cfargument name="primaryKeyHasValue" hint="Pass through if the primary key has value already" type="boolean" required="Yes">
	<cfargument name="generateKey" hint="whether or not to generate a key" type="string" required="Yes">
	<cfscript>
		var columnList = "";
		var property = 0;
		var manytoone = 0;
		var parentOneToMany = 0;
		var iterator = arguments.object.getPropertyIterator();

		//properties
		while(iterator.hasNext())
		{
			property = iterator.next();

			//remove ignore inserts
			if(NOT property.getIgnoreInsert())
			{
				columnList = ListAppend(columnList, property.getColumn());
			}
		}

		//many to one
		iterator = arguments.object.getManyToOneIterator();
		while(iterator.hasNext())
		{
			manytoone = iterator.next();
			columnList = ListAppend(columnList, manyToOne.getLink().getColumn());
		}

		iterator = arguments.object.getParentOneToManyIterator();
		while(iterator.hasNext())
		{
			parentOneToMany = iterator.next();
			columnList = ListAppend(columnList, parentOneToMany.getLink().getColumn());
		}

		//if we add a primary key, add it
		if(primaryKeyHasValue OR arguments.generateKey)
		{
			columnList = ListAppend(columnList, arguments.object.getPrimaryKey().getColumn());
		}

		return columnList;
	</cfscript>
</cffunction>

<cffunction name="invokeSetPrimaryKey" hint="Invokes the setPrimaryKey method on the transfer object" access="private" returntype="void" output="false">
	<cfargument name="transfer" hint="The transfer object to insert" type="transfer.com.TransferObject" required="Yes">
	<cfargument name="primarykeyvalue" hint="The primary key value" type="string" required="Yes">
	<cfscript>
		var object = getObjectManager().getObject(arguments.transfer.getClassName());
		var args = StructNew();

		args[object.getPrimaryKey().getName()] = arguments.primarykeyvalue;

		getMethodInvoker().invokeMethod(arguments.transfer,
										"set" & object.getPrimaryKey().getName(),
										args);
	</cfscript>
</cffunction>

<cffunction name="primaryKeyHasValue" hint="Checks to see if the object's primary key has a value other than default" access="private" returntype="boolean" output="false">
	<cfargument name="transfer" hint="The transfer object" type="transfer.com.TransferObject" required="Yes">
	<cfscript>
		var object = getObjectManager().getObject(arguments.transfer.getClassName());

		//if it's composite, it can never have a value
		if(object.getPrimaryKey().getIsComposite())
		{
			return false;
		}

		return NOT getNullable().checkNullValue(arguments.transfer, object.getPrimaryKey(), invokeGetPrimaryKey(arguments.transfer));
	</cfscript>
</cffunction>

<cffunction name="getIDGenerator" access="private" returntype="IDGenerator" output="false">
	<cfreturn instance.IDGenerator />
</cffunction>

<cffunction name="setIDGenerator" access="private" returntype="void" output="false">
	<cfargument name="IDGenerator" type="IDGenerator" required="true">
	<cfset instance.IDGenerator = arguments.IDGenerator />
</cffunction>

<cffunction name="getNullable" access="private" returntype="Nullable" output="false">
	<cfreturn instance.Nullable />
</cffunction>

<cffunction name="setNullable" access="private" returntype="void" output="false">
	<cfargument name="Nullable" type="Nullable" required="true">
	<cfset instance.Nullable = arguments.Nullable />
</cffunction>

</cfcomponent>